// app_ready_signal.dart

import 'dart:async';
import 'package:flet/flet.dart';
import 'package:flutter/material.dart';

// 🔥 Глобальный Completer, который будет связывать наш контрол и main.dart
final fletAppReadyCompleter = Completer<void>();

// Фабрика для создания нашего контрола
CreateControlFactory createControl = (CreateControlArgs args) {
  if (args.control.type == "app_ready_signal") {
    return AppReadySignalControl(
      control: args.control,
    );
  }
  return null;
};

// Сам виджет контрола
class AppReadySignalControl extends StatelessWidget {
  final Control control;

  const AppReadySignalControl({super.key, required this.control});

  @override
  Widget build(BuildContext context) {
    debugPrint("AppReadySignalControl build: signaling app readiness.");

    // Как только виджет строится, мы завершаем Completer.
    // Проверка isCompleted нужна, чтобы избежать ошибок, если вдруг
    // контрол перерисуется.
    if (!fletAppReadyCompleter.isCompleted) {
      fletAppReadyCompleter.complete();
    }

    // Контрол невидимый, поэтому возвращаем пустой контейнер.
    return const SizedBox.shrink();
  }
}