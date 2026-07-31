import 'dart:async';
import 'dart:io';

import 'package:ip_ntfy_agent/agent.dart';
import 'package:ip_ntfy_agent/config.dart';

Future<void> main(List<String> arguments) async {
  final envPath = arguments.isNotEmpty ? arguments.first : null;
  late final AppConfig config;
  try {
    config = AppConfig.load(envPath);
  } on ConfigException catch (e) {
    stderr.writeln('[config] $e');
    exit(1);
  }

  stdout.writeln('[config] .env OK');
  final agent = Agent(config);

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\n[agent] shutting down...');
    await agent.stop();
    exit(0);
  });

  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      stdout.writeln('\n[agent] shutting down...');
      await agent.stop();
      exit(0);
    });
  }

  try {
    await agent.start();
  } catch (e, st) {
    stderr.writeln('[agent] fatal: $e\n$st');
    await agent.stop();
    exit(1);
  }
}
