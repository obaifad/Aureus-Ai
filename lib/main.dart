import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';
import 'screens/home_screen.dart';
import 'services/app_logger.dart';
import 'services/signal_monitor.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Required so MonitorTaskHandler.sendDataToMain actually reaches
  // SignalMonitor from the foreground-service isolate.
  FlutterForegroundTask.initCommunicationPort();

  await AppLogger.init(isolateTag: 'UI', trim: true);

  // Route uncaught errors into the persisted log instead of losing them.
  FlutterError.onError = (details) {
    AppLogger.log('Flutter error: ${details.exceptionAsString()}');
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.log('Uncaught error: $error\n${stack.toString().split('\n').take(6).join('\n')}');
    return true;
  };

  // Loads .env if present; if missing, AppConfig falls back to safe
  // defaults (mock data mode) so the app still runs out of the box.
  try {
    await dotenv.load(fileName: '.env');
  } catch (e) {
    AppLogger.log('.env not found ($e) — running in mock data mode');
    dotenv.testLoad(fileInput: 'USE_MOCK_DATA=true');
  }

  runApp(const AureusAiApp());
}

class AureusAiApp extends StatelessWidget {
  const AureusAiApp({super.key});

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFD4AF37);

    return ChangeNotifierProvider(
      create: (_) => SignalMonitor(),
      child: MaterialApp(
        title: 'Aureus AI',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: gold,
            brightness: Brightness.dark,
          ),
          scaffoldBackgroundColor: const Color(0xFF0F1115),
        ),
        home: const WithForegroundTask(child: HomeScreen()),
      ),
    );
  }
}
