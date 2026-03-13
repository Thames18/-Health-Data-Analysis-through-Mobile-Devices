// lib/main.dart
//
// UI-friendly Health Data Recorder (IMU + optional mic) with:
// - Step-by-step guidance
// - Big Start/Stop controls + progress bar
// - Live IMU display + accel magnitude sanity check expecting ~9.8 m/s² at rest
// - Saves CSV to app storage AND exports to Downloads/health_data (Android)
// - Shows recently saved file paths + copy-to-clipboard
//
// pubspec.yaml deps (minimum):
//   sensors_plus, path_provider, permission_handler, record, media_store_plus
//

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize MediaStore only on Android
  if (Platform.isAndroid) {
    await MediaStore.ensureInitialized();
    MediaStore.appFolder = "health_data"; // Downloads/health_data
  }

  runApp(const HealthDataRecorderApp());
}

class HealthDataRecorderApp extends StatelessWidget {
  const HealthDataRecorderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Health Data Recorder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const RecorderScreen(),
    );
  }
}

class RecorderScreen extends StatefulWidget {
  const RecorderScreen({super.key});

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  static const Duration defaultTrialDuration = Duration(minutes: 5);

  Duration _trialDuration = defaultTrialDuration;
  int _trialNumber = 1; // 1..3
  bool _recordMic = false;

  bool _isRecording = false;
  DateTime? _recordingStart;
  Duration _elapsed = Duration.zero;

  Timer? _uiTimer;
  Timer? _autoStopTimer;

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  GyroscopeEvent? _latestGyro;

  final List<List<dynamic>> _rows = [];

  AccelerometerEvent? _lastAccel;
  GyroscopeEvent? _lastGyro;

  final List<String> _savedCsv = [];
  final List<String> _savedAudio = [];

  final AudioRecorder _audioRecorder = AudioRecorder();
  String? _audioPath;

  String _status = 'Ready. Press Start to record.';

  @override
  void initState() {
    super.initState();
    _ensureOutDirExists();
  }

  @override
  void dispose() {
    _stopAllTimers();
    _cancelSensorSubs();
    _audioRecorder.dispose();
    super.dispose();
  }

  // Helpers
  String _two(int v) => v.toString().padLeft(2, '0');
  String _formatTimestampForFilename(DateTime dt) {
    return '${dt.year}-${_two(dt.month)}-${_two(dt.day)}_${_two(dt.hour)}-${_two(dt.minute)}-${_two(dt.second)}';
  }

  String _formatDuration(Duration d) {
    final mm = d.inMinutes;
    final ss = d.inSeconds % 60;
    return '${_two(mm)}:${_two(ss)}';
  }

  double get _progress01 {
    if (_trialDuration.inMilliseconds == 0) return 0;
    final p = _elapsed.inMilliseconds / _trialDuration.inMilliseconds;
    return p.clamp(0.0, 1.0);
  }

  double _accMag(AccelerometerEvent? a) {
    if (a == null) return double.nan;
    return sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
  }

  String _magText() {
    final mag = _accMag(_lastAccel);
    return mag.isNaN ? '-' : '${mag.toStringAsFixed(2)} m/s²';
  }

  Future<Directory> _getOutDir() async {
    final base = await getApplicationDocumentsDirectory();
    final out = Directory('${base.path}${Platform.pathSeparator}health_data');
    if (!await out.exists()) {
      await out.create(recursive: true);
    }
    return out;
  }

  Future<void> _ensureOutDirExists() async {
    try {
      await _getOutDir();
    } catch (_) {
      // ignore
    }
  }

  Future<void> _requestPermissionsIfNeeded() async {
    if (_recordMic) {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        throw Exception('Microphone permission denied.');
      }
    }
  }

  /// Ensure a file exists.
  /// If it doesn't exist, create parent dirs and write for CSV.
  Future<void> _ensureFileWritten(String path, {String? text}) async {
    final file = File(path);
    await file.parent.create(recursive: true);

    if (await file.exists()) return;
    // For CSV we always pass text, but keep a safe fallback.
    await file.writeAsString(text ?? '', flush: true);
  }

  Future<void> _exportToDownloadsAndroid(String filePath) async {
    if (!Platform.isAndroid) return;

    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('File not found for export: $filePath');
    }

    final mediaStore = MediaStore();
    await mediaStore.saveFile(
      tempFilePath: filePath,
      dirType: DirType.download,
      dirName: DirName.download,
    );
  }

  Future<void> _exportCrossPlatform(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('File not found: $filePath');
    }

    if (Platform.isIOS) {
      await Share.shareXFiles([XFile(filePath)], text: 'Health data export');
      return;
    }

    if (Platform.isAndroid) {
      await _exportToDownloadsAndroid(filePath);
      return;
    }

    await Share.shareXFiles([XFile(filePath)]);
  }

  void _stopAllTimers() {
    _uiTimer?.cancel();
    _uiTimer = null;
    _autoStopTimer?.cancel();
    _autoStopTimer = null;
  }

  Future<void> _cancelSensorSubs() async {
    await _accelSub?.cancel();
    _accelSub = null;
    await _gyroSub?.cancel();
    _gyroSub = null;
  }

  String _csvEscape(dynamic v) {
    final s = v?.toString() ?? '';
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  void _setTrialDuration(Duration d) {
    if (_isRecording) return;
    setState(() => _trialDuration = d);
  }

  void _resetAll() {
    if (_isRecording) return;
    setState(() {
      _trialNumber = 1;
      _rows.clear();
      _savedCsv.clear();
      _savedAudio.clear();
      _status = 'Ready. Press Start to record.';
    });
    _showSnack('Reset complete.');
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  // Recording

  Future<void> _startRecording() async {
    if (_isRecording) return;

    setState(() => _status = 'Requesting permissions...');

    try {
      await _requestPermissionsIfNeeded();
    } catch (e) {
      setState(() => _status = 'Permission error: $e');
      _showSnack('Permission error. Check microphone permission.');
      return;
    }

    final start = DateTime.now();
    final outDir = await _getOutDir();
    final ts = _formatTimestampForFilename(start);

    _rows
      ..clear()
      ..add(['timestamp_us', 'ax', 'ay', 'az', 'gx', 'gy', 'gz']);
    _latestGyro = null;
    _lastAccel = null;
    _lastGyro = null;

    _audioPath = null;
    if (_recordMic) {
      final canRecord = await _audioRecorder.hasPermission();
      if (!canRecord) {
        setState(() => _status = 'Mic permission not available.');
        _showSnack('Mic permission not available.');
        return;
      }

      _audioPath =
          '${outDir.path}${Platform.pathSeparator}trial_${_trialNumber}_$ts.m4a';

      try {
        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.aacLc,
            sampleRate: 44100,
            bitRate: 128000,
          ),
          path: _audioPath!,
        );
      } catch (e) {
        setState(() => _status = 'Failed to start mic recording: $e');
        _showSnack('Failed to start mic recording.');
        return;
      }
    }

    _gyroSub = gyroscopeEvents.listen((g) {
      _latestGyro = g;
      _lastGyro = g;
    });

    _accelSub = accelerometerEvents.listen((a) {
      final nowUs = DateTime.now().microsecondsSinceEpoch;
      final g = _latestGyro;
      _lastAccel = a;

      _rows.add([
        nowUs,
        a.x,
        a.y,
        a.z,
        g?.x ?? double.nan,
        g?.y ?? double.nan,
        g?.z ?? double.nan,
      ]);
    });

    _recordingStart = start;
    _elapsed = Duration.zero;

    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final st = _recordingStart;
      if (st == null) return;
      setState(() => _elapsed = DateTime.now().difference(st));
    });

    _autoStopTimer = Timer(_trialDuration, () async {
      if (_isRecording) {
        await _stopRecording(autoStopped: true);
      }
    });

    setState(() {
      _isRecording = true;
      _status = 'Recording Trial $_trialNumber...';
    });

    _showSnack('Recording started.');
  }

  Future<void> _stopRecording({bool autoStopped = false}) async {
    if (!_isRecording) return;

    setState(() {
      _status = autoStopped ? 'Auto-stopping & saving...' : 'Stopping & saving...';
    });

    _stopAllTimers();
    await _cancelSensorSubs();

    if (_recordMic) {
      try {
        await _audioRecorder.stop();
      } catch (_) {
        // ignore
      }
    }

    final end = DateTime.now();
    final outDir = await _getOutDir();
    final start = _recordingStart ?? end;
    final ts = _formatTimestampForFilename(start);

    final csvPath =
        '${outDir.path}${Platform.pathSeparator}trial_${_trialNumber}_$ts.csv';

    try {
      // Build CSV text
      final csv = _rows.map((r) => r.map(_csvEscape).join(',')).join('\n');

      // Ensure file exists (fixes "file not found" when exporting)
      await _ensureFileWritten(csvPath, text: csv);

      // Export CSV
      try {
        await _exportCrossPlatform(csvPath);
      } catch (e) {
        setState(() => _status += '\n\nCSV export failed: $e');
        _showSnack('CSV export failed (saved locally).');
      }

      // Export audio only if it really exists
      if (_recordMic && _audioPath != null) {
        final audioFile = File(_audioPath!);
        if (await audioFile.exists()) {
          try {
            await _exportCrossPlatform(_audioPath!);
          } catch (e) {
            setState(() => _status += '\n\nAudio export failed: $e');
            _showSnack('Audio export failed (saved locally).');
          }
        } else {
          setState(() => _status += '\n\nAudio export skipped (file not found).');
        }
      }

      final nextTrial = (_trialNumber < 3) ? _trialNumber + 1 : 3;

      setState(() {
        _isRecording = false;
        _recordingStart = null;
        _elapsed = Duration.zero;

        _savedCsv.insert(0, csvPath);
        if (_recordMic && _audioPath != null) {
          _savedAudio.insert(0, _audioPath!);
        }

        _trialNumber = nextTrial;

        final exportMsg = Platform.isAndroid
            ? 'Copied to Downloads.'
            : Platform.isIOS
                ? 'Use Share → Save to Files.'
                : 'Shared/exported.';

        _status = 'Saved.\nCSV: $csvPath'
            '${_recordMic && _audioPath != null ? '\nAudio: $_audioPath' : ''}'
            '\n\n$exportMsg';
      });

      _showSnack('Saved.');
    } catch (e) {
      setState(() {
        _isRecording = false;
        _recordingStart = null;
        _elapsed = Duration.zero;
        _status = 'Save failed: $e';
      });
      _showSnack('Save failed. See status.');
    }
  }

  // 
  // UI
  // 

  @override
  Widget build(BuildContext context) {
    final accel = _lastAccel;
    final gyro = _lastGyro;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Health Data Recorder'),
        actions: [
          IconButton(
            tooltip: 'Reset',
            onPressed: _isRecording ? null : _resetAll,
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _headerCard(),
                    const SizedBox(height: 12),
                    _progressCard(),
                    const SizedBox(height: 12),
                    _guidanceCard(),
                    const SizedBox(height: 12),
                    _liveSensorCard(accel, gyro),
                    const SizedBox(height: 12),
                    _controlsCard(),
                    const SizedBox(height: 12),
                    _savedFilesCard(),
                    const SizedBox(height: 12),
                    _statusCard(),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _headerCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Trial $_trialNumber / 3',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _recordMic ? 'IMU + Microphone' : 'IMU only',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _pill(
                  label: _isRecording ? 'RECORDING' : 'READY',
                  icon: _isRecording
                      ? Icons.fiber_manual_record
                      : Icons.check_circle,
                  color: _isRecording ? Colors.red : Colors.green,
                ),
                const SizedBox(height: 6),
                Text(
                  'Elapsed: ${_formatDuration(_elapsed)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressCard() {
    final remaining = (_trialDuration - _elapsed);
    final remainingClamped = remaining.isNegative ? Duration.zero : remaining;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Progress',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: _isRecording ? _progress01 : 0),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _isRecording
                        ? 'Time remaining: ${_formatDuration(remainingClamped)}'
                        : 'Ready to record for ${_formatDuration(_trialDuration)}',
                  ),
                ),
                Text(
                  'Samples: ${_rows.isEmpty ? 0 : (_rows.length - 1)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _guidanceCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Steps (what to do)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            _stepRow(1, 'Place phone flat on your chest (screen up).'),
            _stepRow(2, 'Stay still (sitting or lying down) as much as possible.'),
            _stepRow(3, 'Press Start and record 5 minutes (3 trials).'),
            _stepRow(
              4,
              Platform.isAndroid
                  ? 'Press Stop & Save (also copied to Downloads).'
                  : 'Press Stop & Save (then Share → Save to Files).',
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepRow(int n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            child: Text(
              '$n',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  Widget _liveSensorCard(AccelerometerEvent? accel, GyroscopeEvent? gyro) {
    String fmt3(double v) => v.isNaN ? 'NaN' : v.toStringAsFixed(3);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Live sensors (placement check)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            _kvRow(
              'Accelerometer (m/s²)',
              accel == null
                  ? '-'
                  : 'x=${fmt3(accel.x)}  y=${fmt3(accel.y)}  z=${fmt3(accel.z)}',
            ),
            const SizedBox(height: 6),
            _kvRow('Accel magnitude |a|', _magText()),
            const SizedBox(height: 6),
            _kvRow(
              'Gyroscope (rad/s)',
              gyro == null
                  ? '-'
                  : 'x=${fmt3(gyro.x)}  y=${fmt3(gyro.y)}  z=${fmt3(gyro.z)}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Controls',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<Duration>(
              value: _trialDuration,
              decoration: const InputDecoration(
                labelText: 'Trial duration',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(
                  value: Duration(minutes: 5),
                  child: Text('5 minutes (assignment)'),
                ),
                DropdownMenuItem(
                  value: Duration(minutes: 2),
                  child: Text('2 minutes (quick test)'),
                ),
                DropdownMenuItem(
                  value: Duration(minutes: 1),
                  child: Text('1 minute (quick test)'),
                ),
                DropdownMenuItem(
                  value: Duration(seconds: 30),
                  child: Text('30 seconds (quick test)'),
                ),
              ],
              onChanged: _isRecording ? null : (d) => _setTrialDuration(d!),
            ),
            const SizedBox(height: 10),
            SwitchListTile.adaptive(
              value: _recordMic,
              onChanged: _isRecording
                  ? null
                  : (v) {
                      setState(() => _recordMic = v);
                    },
              title: const Text('Record microphone (bonus)'),
              subtitle: const Text('Saves .m4a audio alongside the CSV'),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isRecording ? null : _startRecording,
                    icon: const Icon(Icons.fiber_manual_record),
                    label: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isRecording ? () => _stopRecording() : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop & Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _savedFilesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Saved files (app storage paths)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            if (_savedCsv.isEmpty)
              Text(
                'No files saved yet.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              ..._savedCsv.take(3).map((p) => _fileRow('CSV', p)),
              if (_savedAudio.isNotEmpty)
                ..._savedAudio.take(3).map((p) => _fileRow('Audio', p)),
              const SizedBox(height: 8),
              Text(
                Platform.isAndroid
                    ? 'Android: also copied to Files → Downloads.'
                    : 'iOS: use Share → Save to Files.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fileRow(String tag, String path) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          _pill(label: tag, icon: Icons.insert_drive_file, color: Colors.blueGrey),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Copy path',
            onPressed: () async {
              await _copyToClipboard(path);
              _showSnack('Copied path.');
            },
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: 'Export now',
            onPressed: () async {
              try {
                // If it's a CSV and missing, recreate from current buffer (best-effort).
                if (tag == 'CSV') {
                  final csv = _rows.map((r) => r.map(_csvEscape).join(',')).join('\n');
                  await _ensureFileWritten(path, text: csv);
                }
                await _exportCrossPlatform(path);
                _showSnack(
                  Platform.isAndroid
                      ? 'Copied to Downloads.'
                      : Platform.isIOS
                          ? 'Share opened (Save to Files).'
                          : 'Exported.',
                );
              } catch (e) {
                _showSnack('Export failed: $e');
              }
            },
            icon: const Icon(Icons.ios_share),
          ),
        ],
      ),
    );
  }

  Widget _statusCard() {
    final lastSamples = _rows.length <= 1
        ? const <List<dynamic>>[]
        : _rows
            .skip((_rows.length - 1 - 5).clamp(1, _rows.length - 1))
            .take(5)
            .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Status / Preview',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(_status),
            const SizedBox(height: 10),
            if (lastSamples.isNotEmpty) ...[
              const Divider(),
              const SizedBox(height: 6),
              Text(
                'Last samples (timestamp_us, ax, ay, az)',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              ...lastSamples.map(
                (r) => Text(
                  '${r[0]}  ax=${_fmt(r[1])}  ay=${_fmt(r[2])}  az=${_fmt(r[3])}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmt(dynamic v) {
    if (v is double) return v.isNaN ? 'NaN' : v.toStringAsFixed(3);
    return v.toString();
  }

  Widget _pill({
    required String label,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  Widget _kvRow(String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600))),
        const SizedBox(width: 12),
        Expanded(child: Text(v, textAlign: TextAlign.right)),
      ],
    );
  }
}