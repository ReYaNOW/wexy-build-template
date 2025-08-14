// safe_cupertino_navbar.dart

import 'dart:convert';
import 'package:flet/flet.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

// Фабрика для перехвата создания CupertinoNavigationBar
CreateControlFactory createSafeCupertinoNavBarFactory = (CreateControlArgs args) {
  if (args.control.type.toLowerCase() == "cupertinonavigationbar") {
    return SafeCupertinoNavigationBar(
      parent: args.parent,
      control: args.control,
      children: args.children,
      parentDisabled: args.parentDisabled,
      parentAdaptive: args.parentAdaptive,
      backend: args.backend,
    );
  }
  return null;
};

class SafeCupertinoNavigationBar extends StatefulWidget {
  final Control? parent;
  final Control control;
  final List<Control> children;
  final bool parentDisabled;
  final bool? parentAdaptive;
  final FletControlBackend backend;

  const SafeCupertinoNavigationBar({
    super.key,
    this.parent,
    required this.control,
    required this.children,
    required this.parentDisabled,
    required this.parentAdaptive,
    required this.backend,
  });

  @override
  State<SafeCupertinoNavigationBar> createState() =>
      _SafeCupertinoNavigationBarState();
}

class _SafeCupertinoNavigationBarState extends State<SafeCupertinoNavigationBar>
    with FletStoreMixin {
  int _selectedIndex = 0;

  bool get disabled => widget.control.isDisabled || widget.parentDisabled;

  void _onTap(int index) {
    _selectedIndex = index;
    debugPrint("Selected index: $_selectedIndex");
    widget.backend.updateControlState(
        widget.control.id, {"selectedindex": _selectedIndex.toString()});
    widget.backend.triggerControlEvent(
        widget.control.id, "change", _selectedIndex.toString());
  }

  @override
  Widget build(BuildContext context) {
    debugPrint("SafeCupertinoNavigationBar build: ${widget.control.id}");

    // 🔥 ГЛАВНАЯ ЛОГИКА ЗДЕСЬ

    // 1. Получаем системный отступ снизу. Если он > 0, значит есть панель с кнопками.
    final double bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    // 2. Получаем высоту, заданную в Python.
    final double? originalHeight = widget.control.attrDouble("height");

    // 3. Создаем КОПИЮ настроек оригинального контрола Flet.
    Control controlToBuild = widget.control;

    // 4. Если есть и системный отступ, и заданная высота, вычисляем новую высоту
    //    и создаем новый объект контрола с измененным значением.
    if (bottomPadding > 0 && originalHeight != null) {
      final newHeight = originalHeight + bottomPadding;

      // Создаем копию карты атрибутов
      Map<String, String> newAttrs = Map.from(widget.control.attrs);
      // Обновляем в ней высоту
      newAttrs["height"] = newHeight.toString();

      // Создаем новый объект контрола, который и будем использовать для построения
      controlToBuild = widget.control.copyWith(attrs: newAttrs);
      debugPrint("Applying new height: $newHeight");
    }

    var selectedIndex = widget.control.attrInt("selectedIndex", 0)!;
    if (_selectedIndex != selectedIndex) {
      _selectedIndex = selectedIndex;
    }

    // Собираем сам виджет CupertinoTabBar, как и раньше
    var navBar = withControls(
      widget.children.where((c) => c.isVisible).map((c) => c.id),
      (content, viewModel) {
        return CupertinoTabBar(
          backgroundColor: widget.control.attrColor("bgColor", context),
          activeColor: widget.control.attrColor("activeColor", context) ??
              widget.control.attrColor("indicatorColor", context),
          inactiveColor: widget.control.attrColor("inactiveColor", context) ??
              CupertinoColors.inactiveGray,
          iconSize: widget.control.attrDouble("iconSize", 30.0)!,
          currentIndex: _selectedIndex,
          border: parseBorder(Theme.of(context), widget.control, "border"),
          onTap: disabled ? null : _onTap,
          items: viewModel.controlViews.map((destView) {
            var label = destView.control.attrString("label", "")!;
            var iconStr = parseIcon(destView.control.attrString("icon"));
            var iconCtrls =
                destView.children.where((c) => c.name == "icon" && c.isVisible);
            var selectedIconStr =
                parseIcon(destView.control.attrString("selectedIcon"));
            var selectedIconCtrls = destView.children
                .where((c) => c.name == "selected_icon" && c.isVisible);
            return BottomNavigationBarItem(
              icon: iconCtrls.isNotEmpty
                  ? createControl(destView.control, iconCtrls.first.id,
                      disabled || destView.control.isDisabled,
                      parentAdaptive: widget.parentAdaptive)
                  : Icon(iconStr),
              activeIcon: selectedIconCtrls.isNotEmpty
                  ? createControl(destView.control,
                      selectedIconCtrls.first.id, disabled || destView.control.isDisabled,
                      parentAdaptive: widget.parentAdaptive)
                  : selectedIconStr != null
                      ? Icon(selectedIconStr)
                      : null,
              label: label,
            );
          }).toList(),
        );
      },
    );

    // 5. Передаем в стандартный обработчик Flet наш измененный контрол.
    //    Он сам прочитает из него новую высоту и применит ее.
    return constrainedControl(context, navBar, widget.parent, controlToBuild);
  }
}