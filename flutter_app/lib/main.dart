import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

void main() {
  runApp(const PhaseShiftApp());
}

class PhaseShiftApp extends StatelessWidget {
  const PhaseShiftApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phase_Shift Transcription',
      theme: ThemeData(
        primaryColor: const Color(0xFF1E3A8A),
        scaffoldBackgroundColor: const Color(0xFFF3F4F6),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const TranscriptionScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// --- DATA CLASSES & HELPERS ---

class MidiRecordEvent {
  final int note;
  final int velocity;
  final bool isNoteOn;
  final int timestampMs;

  MidiRecordEvent(this.note, this.velocity, this.isNoteOn, this.timestampMs);
}

class MusicTheory {
  // Moved the notes list to the class level so our UI can use it to build the Key Selector
  static const List<String> notes = [
    'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
  ];

  static String getNoteName(int midiNote) {
    int octave = (midiNote / 12).floor() - 1;
    int noteIndex = midiNote % 12;
    return '${notes[noteIndex]}$octave';
  }

  static List<String> splitNoteAndOctave(String fullNote) {
    if (fullNote.length > 2 && fullNote.contains('#')) {
      return [fullNote.substring(0, 2), fullNote.substring(2)];
    }
    return [fullNote.substring(0, 1), fullNote.substring(1)];
  }
}

// --- MAIN UI & BLUETOOTH LOGIC ---

class TranscriptionScreen extends StatefulWidget {
  const TranscriptionScreen({super.key});

  @override
  State<TranscriptionScreen> createState() => _TranscriptionScreenState();
}

class _TranscriptionScreenState extends State<TranscriptionScreen> {
  BluetoothDevice? esp32Device;
  StreamSubscription<List<ScanResult>>? scanSubscription;
  StreamSubscription<List<int>>? notifySubscription;
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;

  String connectionStatus = 'Disconnected';
  final String targetDeviceName = "Phase_Shift_Mic";
  final Guid serviceUuid = Guid("4fafc201-1fb5-459e-8fcc-c5c9c331914b");
  final Guid characteristicUuid = Guid("beb5483e-36e1-4688-b7f5-ea07361b26a8");

  final ValueNotifier<int> currentMidiNote = ValueNotifier<int>(0);
  final ValueNotifier<int> currentPitchDeviationCents = ValueNotifier<int>(0);
  bool isRecording = false;

  // NEW: User-Friendly Pitch Analyzer Scale Selection
  String selectedScaleType = 'Chromatic'; // 'Chromatic', 'Major', 'Minor'
  int selectedRootNote = 0; // 0 = C, 1 = C#, 2 = D, etc.

  // Dynamically calculate the active scale indices based on user selection
  List<int>? get currentActiveScaleIndices {
    if (selectedScaleType == 'Chromatic') return null; // All notes valid
    
    // Intervals in semitones for Major and Minor scales
    List<int> intervals = selectedScaleType == 'Major' 
        ? [0, 2, 4, 5, 7, 9, 11] // Whole, Whole, Half, Whole, Whole, Whole, Half
        : [0, 2, 3, 5, 7, 8, 10]; // Whole, Half, Whole, Whole, Half, Whole, Whole

    // Apply intervals to the selected root note, wrapping around the 12-note octave
    return intervals.map((interval) => (selectedRootNote + interval) % 12).toList();
  }

  List<MidiRecordEvent> recordedNotes = [];
  Stopwatch recordingStopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    startScan();
  }

  Future<bool> _requestPermissions() async {
    if (Platform.isAndroid) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location, 
      ].request();
      return statuses.values.every((status) => status.isGranted);
    } else if (Platform.isIOS) {
      var status = await Permission.bluetooth.request();
      return status.isGranted;
    }
    return true;
  }

  void startScan() async {
    scanSubscription?.cancel();
    setState(() => connectionStatus = 'Checking Permissions...');

    bool hasPermissions = await _requestPermissions();
    if (!hasPermissions) {
      setState(() => connectionStatus = 'Permissions Denied. Please enable in Settings.');
      return;
    }

    setState(() => connectionStatus = 'Scanning...');

    scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.device.advName == targetDeviceName) {
          FlutterBluePlus.stopScan();
          connectToDevice(r.device);
          break;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

    if (esp32Device == null && connectionStatus == 'Scanning...') {
      setState(() => connectionStatus = 'Device Not Found. Tap to Rescan.');
    }
  }

  void connectToDevice(BluetoothDevice device) async {
    setState(() {
      esp32Device = device;
      connectionStatus = 'Connecting...';
    });

    try {
      await device.connect(license: License.nonprofit);

      connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            connectionStatus = 'Disconnected';
            currentMidiNote.value = 0;
            currentPitchDeviationCents.value = 0;
            if (isRecording) stopRecordingAndExport();
          });
        }
      });

      setState(() => connectionStatus = 'Connected! Discovering...');
      discoverServices(device);
    } catch (e) {
      setState(() => connectionStatus = 'Connection Failed');
    }
  }

  void discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();
    for (var service in services) {
      if (service.uuid == serviceUuid) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid == characteristicUuid) {
            subscribeToCharacteristic(characteristic);
            setState(() => connectionStatus = 'Ready to Transcribe');
            return;
          }
        }
      }
    }
  }

  void subscribeToCharacteristic(BluetoothCharacteristic characteristic) async {
    await characteristic.setNotifyValue(true);
    notifySubscription = characteristic.lastValueStream.listen((value) {
      if (value.isNotEmpty && value.length >= 3) {
        bool isNoteOn = value[0] == 1;
        int midiNote = value[1];
        int velocity = value[2];
        int deviation = 0;

        if (value.length >= 4) {
          deviation = value[3].toSigned(8); 
        }

        if (isRecording && isNoteOn) {
          recordedNotes.add(
            MidiRecordEvent(midiNote, velocity, isNoteOn, recordingStopwatch.elapsedMilliseconds),
          );
        }

        currentMidiNote.value = isNoteOn ? midiNote : 0;
        currentPitchDeviationCents.value = isNoteOn ? deviation : 0;
      }
    });
  }

  void toggleRecording() {
    if (isRecording) {
      stopRecordingAndExport();
    } else {
      startRecording();
    }
  }

  void startRecording() {
    recordedNotes.clear();
    recordingStopwatch.reset();
    recordingStopwatch.start();
    setState(() {
      isRecording = true;
    });
  }

  void stopRecordingAndExport() async {
    recordingStopwatch.stop();
    setState(() {
      isRecording = false;
    });

    if (recordedNotes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No notes recorded!')));
      return;
    }

    final List<MidiRecordEvent> activeNotes = recordedNotes.where((n) => n.isNoteOn).toList();

    if (activeNotes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No valid Note-On events found.')));
      return;
    }

    final pdf = pw.Document();
    
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          return [
            pw.Header(
              level: 0,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Phase_Shift Acoustic Transcription', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: PdfColors.blue900)),
                  pw.Text('VISUAL SCORE SHEET', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.grey700)),
                ],
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Text('Date: ${DateTime.now().toString().split('.')[0]}', style: const pw.TextStyle(fontSize: 10)),
            pw.Text('Total Transcribed Notes: ${activeNotes.length}', style: const pw.TextStyle(fontSize: 10)),
            pw.SizedBox(height: 16),
            pw.Text('1. Visual Transcription Grid Timeline:', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 8),
            pw.Container(
              decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: 1)),
              padding: const pw.EdgeInsets.all(8),
              child: pw.Wrap(
                spacing: 6,
                runSpacing: 6,
                children: List.generate(activeNotes.length, (index) {
                  final event = activeNotes[index];
                  final noteName = MusicTheory.getNoteName(event.note);
                  return pw.Container(
                    width: 70, height: 70,
                    decoration: pw.BoxDecoration(
                      color: PdfColors.blue50,
                      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                      border: pw.Border.all(color: PdfColors.blue300, width: 1),
                    ),
                    child: pw.Column(
                      mainAxisAlignment: pw.MainAxisAlignment.center,
                      children: [
                        pw.Text(noteName, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.blue900)),
                        pw.SizedBox(height: 2),
                        pw.Text('${event.timestampMs}ms', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
                      ],
                    ),
                  );
                }),
              ),
            ),
            pw.SizedBox(height: 24),
            pw.Text('2. Chronological Log Data:', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 8),
            pw.TableHelper.fromTextArray(
              border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blue800),
              headers: ['Event ID', 'Musical Pitch', 'MIDI Key index', 'Onset Time'],
              data: List<List<String>>.generate(activeNotes.length, (index) {
                final event = activeNotes[index];
                return [(index + 1).toString(), MusicTheory.getNoteName(event.note), event.note.toString(), '${event.timestampMs} ms'];
              }),
            ),
          ];
        },
      ),
    );

    try {
      final Directory directory = await getApplicationDocumentsDirectory();
      String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String filePath = '${directory.path}/Phase_Shift_$timestamp.pdf';
      final File file = File(filePath);
      final Uint8List pdfBytes = await pdf.save();
      await file.writeAsBytes(pdfBytes);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Success! PDF saved to:\n$filePath'), duration: const Duration(seconds: 5), backgroundColor: Colors.green),
      );

      await Printing.sharePdf(bytes: pdfBytes, filename: 'Phase_Shift_Sheet_$timestamp.pdf');
    } catch (e) {
      debugPrint("PDF ERROR: $e");
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error rendering PDF: $e'), backgroundColor: Colors.red));
    }
  }

  @override
  void dispose() {
    scanSubscription?.cancel();
    notifySubscription?.cancel();
    connectionSubscription?.cancel();
    esp32Device?.disconnect();
    currentMidiNote.dispose();
    currentPitchDeviationCents.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Phase_Shift Hub', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
        centerTitle: true,
        backgroundColor: const Color(0xFF1E3A8A),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Connection Status Pill
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                decoration: BoxDecoration(
                  color: connectionStatus == 'Ready to Transcribe' ? Colors.green.shade100 : Colors.white,
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4))
                  ],
                  border: Border.all(
                    color: connectionStatus == 'Ready to Transcribe' ? Colors.green.shade400 : Colors.grey.shade300,
                  )
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      connectionStatus == 'Ready to Transcribe' ? Icons.check_circle : Icons.bluetooth_searching,
                      color: connectionStatus == 'Ready to Transcribe' ? Colors.green.shade700 : Colors.grey.shade600,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      connectionStatus,
                      style: TextStyle(
                        fontSize: 14, 
                        fontWeight: FontWeight.w600,
                        color: connectionStatus == 'Ready to Transcribe' ? Colors.green.shade800 : Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            // --- USER-FRIENDLY SCALE SELECTOR ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Analyzer Key/Scale:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                  const SizedBox(height: 4),
                  
                  // Row 1: Scale Type
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: ['Chromatic', 'Major', 'Minor'].map((type) {
                        final isSelected = selectedScaleType == type;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: ChoiceChip(
                            label: Text(type == 'Chromatic' ? 'Chromatic (All Notes)' : type, 
                              style: TextStyle(fontWeight: FontWeight.bold, color: isSelected ? Colors.white : Colors.blue.shade900)
                            ),
                            selected: isSelected,
                            selectedColor: const Color(0xFF1E3A8A),
                            backgroundColor: Colors.blue.shade50,
                            onSelected: (bool selected) {
                              if (selected) setState(() => selectedScaleType = type);
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  
                  // Row 2: Root Note (Smoothly animated so it only appears for Major/Minor modes)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    height: selectedScaleType == 'Chromatic' ? 0 : 45,
                    margin: EdgeInsets.only(top: selectedScaleType == 'Chromatic' ? 0 : 8),
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: MusicTheory.notes.length,
                      itemBuilder: (context, index) {
                        final noteName = MusicTheory.notes[index];
                        final isSelected = selectedRootNote == index;
                        
                        return Padding(
                          padding: const EdgeInsets.only(right: 6.0),
                          child: ChoiceChip(
                            label: Text(noteName, style: TextStyle(fontWeight: FontWeight.bold, color: isSelected ? Colors.white : Colors.blue.shade900)),
                            selected: isSelected,
                            selectedColor: const Color(0xFF1E3A8A),
                            backgroundColor: Colors.blue.shade50,
                            onSelected: (bool selected) {
                              if (selected) setState(() => selectedRootNote = index);
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            // ------------------------------------

            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20.0),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Top Section: Note Display
                        SizedBox(
                          height: 150, 
                          child: ValueListenableBuilder<int>(
                            valueListenable: currentMidiNote,
                            builder: (context, rawNote, child) {
                              if (rawNote == 0) {
                                // Empty state
                                return Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.music_note_rounded, size: 80, color: Colors.grey.shade300),
                                    const SizedBox(height: 16),
                                    Text(
                                      'Play a note...', 
                                      style: TextStyle(fontSize: 18, color: Colors.grey.shade500, fontWeight: FontWeight.w500)
                                    ),
                                  ],
                                );
                              }

                              bool isInScale = true;
                              final activeIndices = currentActiveScaleIndices;
                              if (activeIndices != null) {
                                int pitchClass = rawNote % 12; // 0=C, 1=C#, etc.
                                isInScale = activeIndices.contains(pitchClass);
                              }

                              List<String> noteParts = MusicTheory.splitNoteAndOctave(MusicTheory.getNoteName(rawNote));
                              
                              // If it's a wrong note, turn the text red to warn the user
                              Color displayColor = isInScale ? const Color(0xFF1E3A8A) : Colors.red.shade600;

                              return Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: [
                                      Text(
                                        noteParts[0],
                                        style: TextStyle(fontSize: 120, height: 1.0, fontWeight: FontWeight.bold, color: displayColor),
                                      ),
                                      Text(
                                        noteParts[1],
                                        style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: isInScale ? Colors.grey : Colors.red.shade300),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 30),
                        
                        // Bottom Section: Analyzer (ALWAYS VISIBLE)
                        ValueListenableBuilder<int>(
                          valueListenable: currentMidiNote,
                          builder: (context, rawNote, child) {
                            return ValueListenableBuilder<int>(
                              valueListenable: currentPitchDeviationCents,
                              builder: (context, rawCents, child) {
                                
                                bool isActive = rawNote > 0;
                                bool isInScale = true;

                                if (isActive) {
                                  final activeIndices = currentActiveScaleIndices;
                                  if (activeIndices != null) {
                                    int pitchClass = rawNote % 12;
                                    isInScale = activeIndices.contains(pitchClass);
                                  }
                                }

                                return ProfessionalPitchAnalyzer(
                                  cents: rawCents, 
                                  isActive: isActive,
                                  isInScale: isInScale,
                                );
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Bottom Recording Section
            Container(
              padding: const EdgeInsets.only(top: 20, bottom: 40),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 20, offset: const Offset(0, -5))],
              ),
              child: Column(
                children: [
                  GestureDetector(
                    onTap: connectionStatus == 'Ready to Transcribe' ? toggleRecording : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 90,
                      height: 90,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isRecording ? Colors.red.shade600 : Colors.grey.shade100,
                        boxShadow: [
                          BoxShadow(
                            color: isRecording ? Colors.red.withOpacity(0.4) : Colors.black.withOpacity(0.1),
                            blurRadius: isRecording ? 20 : 10,
                            spreadRadius: isRecording ? 5 : 0,
                            offset: const Offset(0, 5),
                          )
                        ],
                        border: Border.all(
                          color: isRecording ? Colors.red.shade800 : Colors.grey.shade300,
                          width: 4,
                        ),
                      ),
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                          child: Icon(
                            isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                            key: ValueKey(isRecording),
                            color: isRecording ? Colors.white : Colors.grey.shade500,
                            size: 45,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isRecording ? 'Recording Session... Tap to Save' : 'Tap to Start Transcription',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: isRecording ? Colors.red.shade700 : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: startScan,
        backgroundColor: const Color(0xFF1E3A8A),
        tooltip: 'Rescan BLE',
        child: const Icon(Icons.bluetooth_searching, color: Colors.white),
      ),
    );
  }
}

// --- UPGRADED PROFESSIONAL PITCH ANALYZER WIDGET ---

class ProfessionalPitchAnalyzer extends StatelessWidget {
  final int cents;
  final bool isActive;
  final bool isInScale;
  
  const ProfessionalPitchAnalyzer({
    super.key, 
    required this.cents, 
    this.isActive = true,
    this.isInScale = true,
  });

  @override
  Widget build(BuildContext context) {
    bool isPerfect = cents.abs() <= 5;
    bool isFlat = cents < -5;
    bool isWayFlat = cents <= -50;
    bool isWaySharp = cents >= 50;
    
    Color activeColor;
    String statusText;

    // Analyzer Logic Tree
    if (!isActive) {
      activeColor = Colors.grey.shade500;
      statusText = "Listening for Pitch...";
    } else if (!isInScale) {
      // If the note is not in the selected scale/chord
      activeColor = Colors.red.shade600;
      statusText = "Out of Key / Wrong Note ❌";
    } else {
      // Normal tuning feedback for correct notes
      activeColor = isPerfect ? Colors.green.shade500 : (isFlat ? Colors.orange.shade500 : Colors.red.shade500);
      if (isPerfect) {
        statusText = "Perfectly In Tune ✨";
      } else if (isWayFlat) {
        statusText = "Way Too Flat ♭♭";
      } else if (isWaySharp) {
        statusText = "Way Too Sharp ♯♯";
      } else if (isFlat) {
        statusText = "Too Flat ♭";
      } else {
        statusText = "Too Sharp ♯";
      }
    }

    // Map needle position. Lock to center if inactive.
    double screenPercentage = !isActive ? 0.5 : (cents + 50) / 100.0;
    screenPercentage = screenPercentage.clamp(0.0, 1.0);

    return Container(
      width: 320, // Slightly wider for better tick spacing
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937), // Dark, modern dashboard look
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2), 
            blurRadius: 20, 
            offset: const Offset(0, 10)
          )
        ]
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min, // Wrap content tightly
        children: [
          // Text Feedback
          Text(
            statusText,
            style: TextStyle(
              fontSize: 18, 
              fontWeight: FontWeight.bold, 
              color: activeColor,
              letterSpacing: 1.2
            ),
          ),
          const SizedBox(height: 6),
          Text(
            !isActive ? '-- cents' : '${cents > 0 ? '+' : ''}$cents cents',
            style: const TextStyle(
              fontSize: 15, 
              color: Colors.white70,
              fontFeatures: [FontFeature.tabularFigures()] // Keeps text from jumping around
            ),
          ),
          const SizedBox(height: 28),
          
          // The Tuner Dial Scale
          LayoutBuilder(
            builder: (context, constraints) {
              final double trackWidth = constraints.maxWidth;
              // Safe needle position calculation within track width
              final double needlePosition = (trackWidth - 10) * screenPercentage;

              return SizedBox(
                height: 50,
                width: trackWidth,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  clipBehavior: Clip.none, // Allow glow to overflow slightly if needed
                  children: [
                    // Tick Marks Background
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: List.generate(11, (index) {
                        bool isCenter = index == 5;
                        bool isEdge = index == 0 || index == 10;
                        return Container(
                          width: isCenter ? 3 : 2,
                          height: isCenter ? 30 : (isEdge ? 20 : 12),
                          decoration: BoxDecoration(
                            color: isCenter ? Colors.white : Colors.white30,
                            borderRadius: BorderRadius.circular(1),
                          ),
                        );
                      }),
                    ),
                    
                    // Center Target Line (subtle guide)
                    Container(
                      width: 1,
                      height: 40,
                      color: Colors.white24,
                    ),
                    
                    // Animated Gliding Needle
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 200), // Smooth gliding effect
                      curve: Curves.easeOutCirc, // Slightly snappier finish
                      left: needlePosition, 
                      bottom: 0,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Glowing indicator dot
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: activeColor,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: activeColor.withOpacity(0.8), 
                                  blurRadius: 8, 
                                  spreadRadius: 2
                                )
                              ]
                            ),
                          ),
                          const SizedBox(height: 4),
                          // The Needle Line
                          Container(
                            width: 4,
                            height: 36,
                            decoration: BoxDecoration(
                              color: activeColor,
                              borderRadius: BorderRadius.circular(2),
                              boxShadow: [
                                BoxShadow(
                                  color: activeColor.withOpacity(0.5), 
                                  blurRadius: 4, 
                                  spreadRadius: 1
                                )
                              ]
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }
          ),
        ],
      ),
    );
  }
}