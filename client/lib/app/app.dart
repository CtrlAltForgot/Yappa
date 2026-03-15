import 'package:flutter/material.dart';

import '../features/connect/connect_screen.dart';
import '../features/shell/shell_screen.dart';
import 'app_state.dart';
import 'theme.dart';

class YappaApp extends StatefulWidget {
  const YappaApp({super.key});

  @override
  State<YappaApp> createState() => _YappaAppState();
}

class _YappaAppState extends State<YappaApp> {
  late final Future<AppState> _appStateFuture;
  AppState? _appState;

  @override
  void initState() {
    super.initState();
    _appStateFuture = _bootstrap();
  }

  Future<AppState> _bootstrap() async {
    await YappaAppearance.load();
    return AppState.load();
  }

  @override
  void dispose() {
    _appState?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppState>(
      future: _appStateFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildYappaTheme(),
            home: const _BootScreen(),
          );
        }

        if (snapshot.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildYappaTheme(),
            home: _ErrorScreen(errorText: snapshot.error.toString()),
          );
        }

        final appState = snapshot.data!;
        _appState = appState;

        return AnimatedBuilder(
          animation: Listenable.merge([appState, YappaAppearance.notifier]),
          builder: (context, _) {
            return MaterialApp(
              title: 'Yappa',
              debugShowCheckedModeBanner: false,
              theme: buildYappaTheme(),
              home: appState.hasActiveSession
                  ? ShellScreen(appState: appState)
                  : ConnectScreen(appState: appState),
            );
          },
        );
      },
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 18),
            Text('Loading saved nodes and Yappa settings...'),
          ],
        ),
      ),
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  final String errorText;

  const _ErrorScreen({required this.errorText});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 42),
              const SizedBox(height: 16),
              const Text('Yappa could not boot cleanly.'),
              const SizedBox(height: 10),
              Text(errorText, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}