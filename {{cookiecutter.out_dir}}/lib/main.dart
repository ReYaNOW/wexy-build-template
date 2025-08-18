import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

import 'package:flet/flet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:serious_python/serious_python.dart';
import 'package:url_strategy/url_strategy.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import "python.dart";
import 'app_ready_signal.dart' as app_ready_signal;
import 'package:flet_cacheimg/flet_cacheimg.dart' as flet_cacheimg;
import 'safe_cupertino_navbar.dart' as safe_cupertino_navbar;

const bool isProduction = bool.fromEnvironment('dart.vm.product');

const assetPath = "app/app.zip";
const pythonModuleName = "main";
const appBootScreenMessage = 'Загрузка';

List<CreateControlFactory> createControlFactories = [
  safe_cupertino_navbar.createSafeCupertinoNavBarFactory,
  app_ready_signal.createControl,
  flet_cacheimg.createControl,
];

String outLogFilename = "";

// global vars
List<String> _args = [];
String pageUrl = "";
String assetsDir = "";
String appDir = "";
Map<String, String> environmentVariables = {};

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(
      widgetsBinding: WidgetsFlutterBinding.ensureInitialized());

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.transparent,
    statusBarColor: Colors.transparent,
  ));

  _args = List<String>.from(args);
  await prepareApp();

  FlutterNativeSplash.remove();

  runApp(const FletAppLoader());
}

class FletAppLoader extends StatefulWidget {
  const FletAppLoader({super.key});

  @override
  State<FletAppLoader> createState() => _FletAppLoaderState();
}

// 🔥 ДОБАВЛЯЕМ 'WidgetsBindingObserver' ДЛЯ ОТСЛЕЖИВАНИЯ ЖИЗНЕННОГО ЦИКЛА
class _FletAppLoaderState extends State<FletAppLoader> with WidgetsBindingObserver {
  static const _startupTimeout = Duration(seconds: 5);
  static const _animationDuration = Duration(milliseconds: 500);

  bool _isPythonServerReady = false;
  bool _isFletAppReady = false;
  String? _startupError;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();

    // 🔥 РЕГИСТРИРУЕМ ОБРАБОТЧИК ЖИЗНЕННОГО ЦИКЛА
    WidgetsBinding.instance.addObserver(this);

    _timeoutTimer = Timer(_startupTimeout, () {
      if (mounted && !_isFletAppReady) {
        _hideBootScreenAndRestoreUI();
      }
    });

    // Ждем сигнала от Flet, что UI готов
    app_ready_signal.fletAppReadyCompleter.future.then((_) {
      debugPrint("AppReadySignal received: UI is fully ready.");
      if (mounted) {
        _hideBootScreenAndRestoreUI();
      }
    });

    // Стандартная логика запуска Python
    if (!kIsWeb && !(_args.isNotEmpty && isDesktopPlatform())) {
      runPythonApp(_args).then((error) {
        if (error != null) {
          debugPrint("Python app exited with error: $error");
          if (mounted && !_isFletAppReady) {
            _timeoutTimer?.cancel();
            setState(() {
              _startupError = error;
            });
          }
        }
      });
      _probeForPythonServer();
    } else {
      _isPythonServerReady = true;
    }
  }

  // 🔥 ГЛАВНЫЙ ФИКС ЗДЕСЬ
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Нас интересует только состояние 'detached' на Android.
    // Это состояние наступает, когда приложение закрывается (например, кнопкой "назад").
    if (defaultTargetPlatform == TargetPlatform.android && state == AppLifecycleState.detached) {
      // Если Flet UI еще не готов, это означает, что Python-сервер
      // может находиться в промежуточном состоянии, и его обработчик
      // os._exit(1) еще не зарегистрирован.
      // Чтобы предотвратить сбой при следующем запуске, мы принудительно
      // завершаем весь процесс, имитируя поведение Python-фикса.
      if (!_isFletAppReady) {
        debugPrint(
            "App detached during boot. Force exiting to prevent crash on next launch.");
        exit(0); // Принудительно убиваем процесс.
      }
    }
  }

  void _hideBootScreenAndRestoreUI() {
    _timeoutTimer?.cancel();

    if (!mounted) return;

    // Шаг 1: Меняем состояние, чтобы запустить анимацию скрытия BootScreen
    setState(() {
      _isFletAppReady = true;
    });

    // Шаг 2: Через 500 мс (когда анимация завершится) возвращаем системный UI
    Future.delayed(_animationDuration, () {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    });
  }

  Future<void> _probeForPythonServer() async {
    debugPrint("Starting Python server probe...");
    const probeTimeout = Duration(seconds: 15);
    final stopwatch = Stopwatch()..start();

    while (stopwatch.elapsed < probeTimeout) {
      if (!mounted) return;

      try {
        final udsFile = File(pageUrl);
        if (await udsFile.exists()) {
          debugPrint(
              "✅ Python server socket found! Proceeding to connect FletApp.");
          if (mounted) {
            setState(() {
              _isPythonServerReady = true;
            });
          }
          return;
        }
      } catch (e) {
        debugPrint("Probe error: $e");
      }

      await Future.delayed(const Duration(milliseconds: 300));
    }

    debugPrint(
        "Probe timed out. Python server socket did not appear in time.");
  }

  @override
  void dispose() {
    // 🔥 ОБЯЗАТЕЛЬНО УДАЛЯЕМ ОБРАБОТЧИК ПРИ УНИЧТОЖЕНИИ ВИДЖЕТА
    WidgetsBinding.instance.removeObserver(this);
    _timeoutTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || (_args.isNotEmpty && isDesktopPlatform())) {
      _timeoutTimer?.cancel();
      return MediaQuery.withClampedTextScaling(
        minScaleFactor: 0.8,
        maxScaleFactor: 1.1,
        child: FletApp(
          pageUrl: pageUrl,
          assetsDir: assetsDir,
          createControlFactories: createControlFactories,
        ),
      );
    }

    if (_startupError != null) {
      return MediaQuery.withClampedTextScaling(
        minScaleFactor: 0.8,
        maxScaleFactor: 1.1,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: ErrorScreen(
              title: "Ошибка при запуске приложения", text: _startupError!),
        ),
      );
    }

    if (!_isPythonServerReady) {
      return const BootScreen();
    } else {
      return MediaQuery.withClampedTextScaling(
        minScaleFactor: 0.8,
        maxScaleFactor: 1.1,
        child: Stack(
          children: [
            FletApp(
              pageUrl: pageUrl,
              assetsDir: assetsDir,
              createControlFactories: createControlFactories,
            ),
            AnimatedSwitcher(
              duration: _animationDuration,
              transitionBuilder: (Widget child, Animation<double> animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: !_isFletAppReady
                  ? const BootScreen(key: ValueKey('BootScreen'))
                  : const SizedBox.shrink(key: ValueKey('Empty')),
            ),
          ],
        ),
      );
    }
  }
}

Future prepareApp() async {
  // Логирование теперь включено по умолчанию для отладки
  await setupDesktop();

  flet_cacheimg.ensureInitialized();
  appDir = await extractAssetZip(assetPath, checkHash: true);
  await Future.delayed(const Duration(seconds: 2));

  if (kIsWeb) {
    pageUrl = Uri.base.toString();
    var routeUrlStrategy = getFletRouteUrlStrategy();
    if (routeUrlStrategy == "path") {
      setPathUrlStrategy();
    }
  } else if (_args.isNotEmpty && isDesktopPlatform()) {
    debugPrint("Flet app is running in Developer mode");
    pageUrl = _args[0];
    if (_args.length > 1) {
      var pidFilePath = _args[1];
      debugPrint("Args contain a path to PID file: $pidFilePath}");
      var pidFile = await File(pidFilePath).create();
      await pidFile.writeAsString("$pid");
    }
    if (_args.length > 2) {
      assetsDir = _args[2];
      debugPrint("Args contain a path assets directory: $assetsDir}");
    }
  } else {

    Directory.current = appDir;
    assetsDir = path.join(appDir, "assets");

    WidgetsFlutterBinding.ensureInitialized();

    var appTempPath = (await path_provider.getApplicationCacheDirectory()).path;
    var appDataPath =
        (await path_provider.getApplicationDocumentsDirectory()).path;

    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.android) {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();
      appDataPath = path.join(appDataPath, "flet", packageInfo.packageName);
      if (!await Directory(appDataPath).exists()) {
        await Directory(appDataPath).create(recursive: true);
      }
    }

    environmentVariables["FLET_APP_STORAGE_DATA"] = appDataPath;
    environmentVariables["FLET_APP_STORAGE_TEMP"] = appTempPath;
    outLogFilename = path.join(appTempPath, "console.log");
    environmentVariables["FLET_APP_CONSOLE"] = outLogFilename;
    environmentVariables["FLET_PLATFORM"] =
        defaultTargetPlatform.name.toLowerCase();

    if (defaultTargetPlatform == TargetPlatform.windows) {
      var tcpPort = await getUnusedPort();
      pageUrl = "tcp://localhost:$tcpPort";
      environmentVariables["FLET_SERVER_PORT"] = tcpPort.toString();
    } else {
      pageUrl = "flet_$pid.sock";
      environmentVariables["FLET_SERVER_UDS_PATH"] = pageUrl;
    }
  }
  return "";
}

Future<String?> runPythonApp(List<String> args) async {
  var argvItems = args.map((a) => "\"${a.replaceAll('"', '\\"')}\"");
  var argv = "[${argvItems.isNotEmpty ? argvItems.join(',') : '""'}]";
  var script = pythonScript
      .replaceAll("{outLogFilename}", outLogFilename.replaceAll("\\", "\\\\"))
      .replaceAll('{module_name}', pythonModuleName)
      .replaceAll('{argv}', argv);

  var completer = Completer<String>();
  ServerSocket outSocketServer;
  String socketAddr = "";
  StringBuffer pythonOut = StringBuffer();

  if (defaultTargetPlatform == TargetPlatform.windows) {
    var tcpAddr = "127.0.0.1";
    outSocketServer = await ServerSocket.bind(tcpAddr, 0);
    debugPrint(
        'Python output TCP Server is listening on port ${outSocketServer.port}');
    socketAddr = "$tcpAddr:${outSocketServer.port}";
  } else {
    socketAddr = "stdout_$pid.sock";
    if (await File(socketAddr).exists()) {
      await File(socketAddr).delete();
    }
    outSocketServer = await ServerSocket.bind(
        InternetAddress(socketAddr, type: InternetAddressType.unix), 0);
    debugPrint('Python output Socket Server is listening on $socketAddr');
  }

  environmentVariables["FLET_PYTHON_CALLBACK_SOCKET_ADDR"] = socketAddr;

  void closeOutServer() async {
    outSocketServer.close();
    int exitCode = int.tryParse(pythonOut.toString().trim()) ?? 0;
    if (exitCode == errorExitCode) {
      var out = "";
      if (await File(outLogFilename).exists()) {
        out = await File(outLogFilename).readAsString();
      }
      completer.complete(out);
    } else {
      exit(exitCode);
    }
  }

  SeriousPython.runProgram(path.join(appDir, "$pythonModuleName.pyc"),
      script: script, environmentVariables: environmentVariables);

  await Future.delayed(const Duration(milliseconds: 300));

  outSocketServer.listen((client) {
    debugPrint(
        'Connection from: ${client.remoteAddress.address}:${client.remotePort}');
    client.listen((data) {
      var s = String.fromCharCodes(data);
      pythonOut.write(s);
    }, onError: (error) {
      client.close();
      closeOutServer();
    }, onDone: () {
      client.close();
      closeOutServer();
    });
  });



  return completer.future;
}

class ErrorScreen extends StatelessWidget {
  final String title;
  final String text;
  const ErrorScreen({super.key, required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
          child: Container(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  },
                  icon: const Icon(
                    Icons.copy,
                    size: 16,
                  ),
                  label: const Text("Copy"),
                )
              ],
            ),
            Expanded(
                child: SingleChildScrollView(
              child: SelectableText(text,
                  style: Theme.of(context).textTheme.bodySmall),
            ))
          ],
        ),
      )),
    );
  }
}

class BootScreen extends StatelessWidget {
  const BootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF000000),
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(),
            const Center(
              child: Image(
                image: AssetImage('images/icon.png'),
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      appBootScreenMessage,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        decoration: TextDecoration.none,
                        fontFamily: '.SF UI Text',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class BlankScreen extends StatelessWidget {
  const BlankScreen({
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SizedBox.shrink(),
    );
  }
}

Future<int> getUnusedPort() {
  return ServerSocket.bind("127.0.0.1", 0).then((socket) {
    var port = socket.port;
    socket.close();
    return port;
  });
}

Future setupDesktop() async {
  if (isDesktopPlatform()) {
    WidgetsFlutterBinding.ensureInitialized();
    await windowManager.ensureInitialized();

    Map<String, String> env = Platform.environment;
    var hideWindowOnStart = env["FLET_HIDE_WINDOW_ON_START"];
    var hideAppOnStart = env["FLET_HIDE_APP_ON_START"];
    debugPrint("hideWindowOnStart: $hideWindowOnStart");
    debugPrint("hideAppOnStart: $hideAppOnStart");

    await windowManager.waitUntilReadyToShow(null, () async {
      if (hideWindowOnStart == null && hideAppOnStart == null) {
        await windowManager.show();
        await windowManager.focus();
      } else if (hideAppOnStart != null) {
        await windowManager.setSkipTaskbar(true);
      }
    });
  }
}