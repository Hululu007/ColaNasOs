import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_settings.dart';
import 'tv_focus.dart';

/// 是否走 TV 输入链路：只在「TV 版面 + Android」生效。
///
/// 不用编译期 `kTvBuild`：打包参数 `COLANAS_TV=1` 不是合法 bool，
/// `bool.fromEnvironment` 只认 `true`，靠运行期的 `tvMode` 更可靠；
/// TV 入口 `main_tv.dart` 启动时会把它置 true。桌面 / 手机 / Web 保持原逻辑。
bool get tvInputEnabled =>
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.android &&
    AppSettings.instance.tvMode.value;

/// 屏幕键盘返回结果。
///
/// [systemIme] = 用户明确要求改用系统输入法（可选路径），此时 [text] 是已输入内容。
class TvKeyboardResult {
  const TvKeyboardResult({required this.text, this.systemIme = false});

  final String text;
  final bool systemIme;
}

/// 打开 TV 屏幕键盘。返回 null = 取消。
Future<TvKeyboardResult?> showTvKeyboard(
  BuildContext context, {
  required String title,
  String initialText = '',
  bool obscure = false,
  bool numbersOnly = false,
  int? maxLength,
}) {
  return showDialog<TvKeyboardResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TvKeyboardDialog(
      title: title,
      initialText: initialText,
      obscure: obscure,
      numbersOnly: numbersOnly,
      maxLength: maxLength,
    ),
  );
}

enum _KeyboardPage { letters, numbers, symbols }

enum _KeyAction {
  shift,
  backspace,
  clear,
  space,
  letters,
  numbers,
  symbols,
  system,
  cancel,
  confirm,
}

class _KeyCap {
  const _KeyCap({
    required this.label,
    this.insert,
    this.action,
    this.flex = 1,
  });

  final String label;

  /// 按下后追加到文本末尾的字符（与 [action] 互斥）。
  final String? insert;
  final _KeyAction? action;

  /// 相对宽度：1 = 一个字符键。
  final int flex;
}

/// TV 屏幕键盘。
///
/// Android TV 的系统 IME 在部分固件上不会随焦点弹出（已两次真机确认），
/// 因此这里用纯 Flutter 画一个键盘：只有一个 [FocusNode]，四向移动 / 确认 /
/// 退格 / 取消全部由本组件显式解析，不依赖平台默认焦点遍历与输入法。
class _TvKeyboardDialog extends StatefulWidget {
  const _TvKeyboardDialog({
    required this.title,
    required this.initialText,
    required this.obscure,
    required this.numbersOnly,
    this.maxLength,
  });

  final String title;
  final String initialText;
  final bool obscure;
  final bool numbersOnly;
  final int? maxLength;

  @override
  State<_TvKeyboardDialog> createState() => _TvKeyboardDialogState();
}

class _TvKeyboardDialogState extends State<_TvKeyboardDialog> {
  static final Set<LogicalKeyboardKey> _okKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
  };

  static final Set<PhysicalKeyboardKey> _okPhysical = <PhysicalKeyboardKey>{
    PhysicalKeyboardKey.enter,
    PhysicalKeyboardKey.numpadEnter,
    PhysicalKeyboardKey.select,
    PhysicalKeyboardKey.gameButtonA,
  };

  final FocusNode _focusNode = FocusNode(debugLabel: 'tv-keyboard');

  late String _text = widget.initialText;
  late _KeyboardPage _page = widget.numbersOnly
      ? _KeyboardPage.numbers
      : _KeyboardPage.letters;
  bool _shift = false;
  int _row = 0;
  int _col = 0;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 键位
  // ---------------------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final ok = _okKeys.contains(key) || _okPhysical.contains(event.physicalKey);
    if (event is KeyDownEvent) {
      if (ok) {
        _activate();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.backspace) {
        _backspace();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.space) {
        _insert(' ');
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.browserBack) {
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      }
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _move(0, -1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _move(0, 1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _move(-1, 0);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _move(1, 0);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _move(int rowDelta, int colDelta) {
    final rows = _rows;
    if (rows.isEmpty) return;
    var row = (_row + rowDelta).clamp(0, rows.length - 1);
    var col = (colDelta != 0 ? _col + colDelta : _col)
        .clamp(0, rows[row].length - 1);
    if (row == _row && col == _col) return;
    setState(() {
      _row = row;
      _col = col;
    });
  }

  void _insert(String value) {
    final max = widget.maxLength;
    if (max != null && _text.length + value.length > max) return;
    setState(() => _text += value);
  }

  void _backspace() {
    if (_text.isEmpty) return;
    setState(() => _text = _text.substring(0, _text.length - 1));
  }

  void _switchPage(_KeyboardPage page) {
    setState(() {
      _page = page;
      _row = 0;
      _col = 0;
    });
  }

  void _activate() {
    final rows = _rows;
    if (_row < 0 || _row >= rows.length) return;
    final row = rows[_row];
    if (_col < 0 || _col >= row.length) return;
    final cap = row[_col];
    if (cap.insert != null) {
      _insert(cap.insert!);
      return;
    }
    switch (cap.action!) {
      case _KeyAction.shift:
        setState(() => _shift = !_shift);
      case _KeyAction.backspace:
        _backspace();
      case _KeyAction.clear:
        setState(() => _text = '');
      case _KeyAction.space:
        _insert(' ');
      case _KeyAction.letters:
        _switchPage(_KeyboardPage.letters);
      case _KeyAction.numbers:
        _switchPage(_KeyboardPage.numbers);
      case _KeyAction.symbols:
        _switchPage(_KeyboardPage.symbols);
      case _KeyAction.system:
        Navigator.of(context).pop(
          TvKeyboardResult(text: _text, systemIme: true),
        );
      case _KeyAction.cancel:
        Navigator.of(context).pop();
      case _KeyAction.confirm:
        Navigator.of(context).pop(TvKeyboardResult(text: _text));
    }
  }

  // ---------------------------------------------------------------------------
  // 键位数据
  // ---------------------------------------------------------------------------

  List<List<_KeyCap>> get _rows => switch (_page) {
    _KeyboardPage.letters => _lettersRows,
    _KeyboardPage.numbers => _numbersRows,
    _KeyboardPage.symbols => _symbolsRows,
  };

  List<_KeyCap> _chars(String chars) {
    final upper = _page == _KeyboardPage.letters && _shift;
    return <_KeyCap>[
      for (final ch in chars.split(''))
        _KeyCap(label: upper ? ch.toUpperCase() : ch, insert: upper ? ch.toUpperCase() : ch),
    ];
  }

  List<List<_KeyCap>> get _lettersRows => <List<_KeyCap>>[
    _chars('qwertyuiop'),
    _chars('asdfghjkl'),
    <_KeyCap>[
      _KeyCap(
        label: tr('tv.keyboard.shift'),
        action: _KeyAction.shift,
        flex: 2,
      ),
      ..._chars('zxcvbnm'),
      _KeyCap(
        label: tr('tv.keyboard.backspace'),
        action: _KeyAction.backspace,
        flex: 2,
      ),
    ],
    _actionRow(),
    _confirmRow(),
  ];

  List<List<_KeyCap>> get _numbersRows => <List<_KeyCap>>[
    _chars('1234567890'),
    _chars('-_.:/+=%#'),
    _chars('@!~,;*()\'"'),
    _actionRow(),
    _confirmRow(),
  ];

  List<List<_KeyCap>> get _symbolsRows => <List<_KeyCap>>[
    _chars('[]{}<>|\\^'),
    _chars('&@#%*+=_-'),
    _chars('!?,.:;\'"~¥'),
    _actionRow(),
    _confirmRow(),
  ];

  List<_KeyCap> _actionRow() => <_KeyCap>[
    if (_page != _KeyboardPage.letters)
      _KeyCap(
        label: tr('tv.keyboard.letters'),
        action: _KeyAction.letters,
      ),
    if (_page != _KeyboardPage.numbers)
      _KeyCap(
        label: tr('tv.keyboard.numbers'),
        action: _KeyAction.numbers,
      ),
    if (_page != _KeyboardPage.symbols)
      _KeyCap(label: tr('tv.keyboard.symbols'), action: _KeyAction.symbols),
    _KeyCap(
      label: tr('tv.keyboard.space'),
      action: _KeyAction.space,
      flex: 2,
    ),
    _KeyCap(label: tr('tv.keyboard.clear'), action: _KeyAction.clear),
    _KeyCap(label: tr('tv.keyboard.system'), action: _KeyAction.system),
  ];

  List<_KeyCap> _confirmRow() => <_KeyCap>[
    _KeyCap(
      label: tr('tv.keyboard.cancel'),
      action: _KeyAction.cancel,
      flex: 3,
    ),
    _KeyCap(
      label: tr('tv.keyboard.confirm'),
      action: _KeyAction.confirm,
      flex: 3,
    ),
  ];

  // ---------------------------------------------------------------------------
  // 渲染
  // ---------------------------------------------------------------------------

  String get _displayText {
    if (!widget.obscure) return _text;
    return '•' * _text.length;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    final maxUnits = rows.fold<int>(0, (best, row) {
      final units = row.fold<int>(0, (sum, cap) => sum + cap.flex);
      return units > best ? units : best;
    });
    const pad = 24.0;
    const gap = 8.0;
    final width = (media.size.width * 0.84).clamp(360.0, 1120.0).toDouble();
    final unit = (width - pad * 2 - (maxUnits - 1) * gap) / maxUnits;
    final budget = ((media.size.height - 240) / (rows.length + 1))
        .clamp(24.0, 68.0)
        .toDouble();
    final byWidth = (unit * 0.72).clamp(32.0, 68.0).toDouble();
    final keyHeight = byWidth < budget ? byWidth : budget;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(pad),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Material(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(pad),
            child: Focus(
              focusNode: _focusNode,
              autofocus: true,
              onKeyEvent: _onKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        tr('tv.keyboard.hint'),
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    height: (keyHeight * 1.2).clamp(46.0, 74.0).toDouble(),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.centerLeft,
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: scheme.onSurface.withValues(alpha: 0.14),
                      ),
                    ),
                    child: Text(
                      _displayText.isEmpty
                          ? tr('tv.keyboard.hint')
                          : _tailOf(_displayText),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w600,
                        color: _displayText.isEmpty
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  for (var r = 0; r < rows.length; r += 1) ...[
                    if (r > 0) const SizedBox(height: 8),
                    _buildRow(rows[r], r, unit, gap, keyHeight),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 长文本只显示尾部，避免一直看到开头、看不到刚输入的字。
  static String _tailOf(String text) =>
      text.length <= 42 ? text : '…${text.substring(text.length - 41)}';

  Widget _buildRow(
    List<_KeyCap> row,
    int rowIndex,
    double unit,
    double gap,
    double height,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < row.length; i += 1) ...[
          if (i > 0) SizedBox(width: gap),
          SizedBox(
            width: row[i].flex * unit + (row[i].flex - 1) * gap,
            height: height,
            child: _buildKey(row[i], rowIndex, i),
          ),
        ],
      ],
    );
  }

  Widget _buildKey(_KeyCap cap, int rowIndex, int colIndex) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _row == rowIndex && _col == colIndex;
    final confirm = cap.action == _KeyAction.confirm;
    final cancel = cap.action == _KeyAction.cancel;
    final background = selected
        ? scheme.primary
        : confirm
        ? scheme.primary.withValues(alpha: 0.2)
        : scheme.onSurface.withValues(alpha: 0.07);
    final foreground = selected
        ? scheme.onPrimary
        : cancel
        ? scheme.error
        : scheme.onSurface;
    final isChar = cap.insert != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() {
          _row = rowIndex;
          _col = colIndex;
        });
        _activate();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Text(
              cap.label,
              maxLines: 1,
              style: TextStyle(
                fontSize: isChar ? 24 : 16,
                fontWeight: isChar ? FontWeight.w600 : FontWeight.w700,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// TV 端文本输入字段：UI 上是一块只读的显示区，按 OK 打开屏幕键盘。
///
/// 系统 IME 只在键盘里按「系统键盘」时才作为可选项启用，默认路径不依赖它。
class TvKeyboardField extends StatefulWidget {
  const TvKeyboardField({
    super.key,
    required this.controller,
    required this.focusNode,
    this.labelText,
    this.hintText,
    this.prefixIcon,
    this.autofocus = false,
    this.obscureText = false,
    this.numbersOnly = false,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
    this.nextFocusNodes = const <FocusNode>[],
    this.previousFocusNodes = const <FocusNode>[],
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String? labelText;
  final String? hintText;
  final Widget? prefixIcon;
  final bool autofocus;
  final bool obscureText;

  /// 只给数字键盘（2FA 验证码）。
  final bool numbersOnly;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// 「右 / 下」要去的地方：按顺序取第一个可聚焦且已挂载的节点。
  final List<FocusNode> nextFocusNodes;

  /// 「左 / 上」要去的地方，规则同上。
  final List<FocusNode> previousFocusNodes;

  @override
  State<TvKeyboardField> createState() => _TvKeyboardFieldState();
}

class _TvKeyboardFieldState extends State<TvKeyboardField> {
  static final Set<LogicalKeyboardKey> _okKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.space,
  };

  static final Set<PhysicalKeyboardKey> _okPhysical = <PhysicalKeyboardKey>{
    PhysicalKeyboardKey.enter,
    PhysicalKeyboardKey.numpadEnter,
    PhysicalKeyboardKey.select,
    PhysicalKeyboardKey.gameButtonA,
  };

  /// 系统 IME 可选模式（从屏幕键盘里的「系统键盘」进入）。
  bool _systemMode = false;

  /// 系统模式下的「退出」按钮节点。
  final FocusNode _exitFocus = FocusNode(debugLabel: 'tv-field-exit-ime');

  @override
  void dispose() {
    _exitFocus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_okKeys.contains(key) || _okPhysical.contains(event.physicalKey)) {
      _openKeyboard();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      return _moveFrom(widget.nextFocusNodes, TraversalDirection.down);
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      return _moveFrom(widget.previousFocusNodes, TraversalDirection.up);
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _moveFrom(
    List<FocusNode> nodes,
    TraversalDirection direction,
  ) {
    final target = _firstFocusable(nodes);
    if (target != null) {
      target.requestFocus();
      return KeyEventResult.handled;
    }
    final focus = FocusManager.instance.primaryFocus;
    final moved = focus?.focusInDirection(direction) ?? false;
    return moved ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  FocusNode? _firstFocusable(List<FocusNode> nodes) {
    for (final node in nodes) {
      if (!node.canRequestFocus || node.context == null) continue;
      return node;
    }
    return null;
  }

  Future<void> _openKeyboard() async {
    if (_systemMode) return;
    final result = await showTvKeyboard(
      context,
      title: widget.labelText ?? '',
      initialText: widget.controller.text,
      obscure: widget.obscureText,
      numbersOnly: widget.numbersOnly,
      maxLength: widget.maxLength,
    );
    if (!mounted) return;
    if (result == null) {
      // 取消：把焦点还回输入框，方向键可以继续往下走。
      widget.focusNode.requestFocus();
      return;
    }
    if (result.text != widget.controller.text) {
      widget.controller.text = result.text;
      widget.controller.selection = TextSelection.collapsed(
        offset: result.text.length,
      );
      widget.onChanged?.call(result.text);
    }
    if (result.systemIme) {
      _enterSystemMode();
      return;
    }
    widget.focusNode.requestFocus();
    widget.onSubmitted?.call(result.text);
  }

  void _enterSystemMode() {
    setState(() => _systemMode = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.focusNode.requestFocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    });
  }

  void _exitSystemMode({FocusNode? moveTo}) {
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    if (!mounted) return;
    setState(() => _systemMode = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (moveTo ?? widget.focusNode).requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 系统键盘模式下拦截返回键：先退出 IME，而不是把应用退出掉。
      canPop: !_systemMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _exitSystemMode();
      },
      child: _systemMode ? _buildSystemField(context) : _buildDisplay(context),
    );
  }

  Widget _buildDisplay(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: TvFocusCard(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onTap: _openKeyboard,
        radius: 12,
        focusScale: 1.01,
        child: Container(
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: scheme.onSurface.withValues(alpha: 0.16),
            ),
          ),
          child: Row(
            children: [
              if (widget.prefixIcon != null) ...[
                widget.prefixIcon!,
                const SizedBox(width: 10),
              ],
              Expanded(
                child: AnimatedBuilder(
                  animation: widget.controller,
                  builder: (context, _) {
                    final value = widget.controller.text;
                    final shown = widget.obscureText
                        ? '•' * value.length
                        : value;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.labelText != null)
                          Text(
                            widget.labelText!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        if (widget.labelText != null)
                          const SizedBox(height: 2),
                        Text(
                          shown.isEmpty
                              ? (widget.hintText ?? '')
                              : shown,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: widget.obscureText ? 1.5 : 0,
                            color: shown.isEmpty
                                ? scheme.onSurfaceVariant
                                : scheme.onSurface,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.keyboard_alt_outlined,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 132),
                child: Text(
                  tr('tv.field.openHint'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSystemField(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.escape ||
                key == LogicalKeyboardKey.goBack ||
                key == LogicalKeyboardKey.browserBack) {
              _exitSystemMode();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            autofocus: true,
            obscureText: widget.obscureText,
            keyboardType: widget.numbersOnly
                ? TextInputType.number
                : TextInputType.text,
            maxLength: widget.maxLength,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            decoration: InputDecoration(
              labelText: widget.labelText,
              hintText: widget.hintText,
              prefixIcon: widget.prefixIcon,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                tr('tv.field.systemHint'),
                maxLines: 2,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TvFocusCard(
              focusNode: _exitFocus,
              radius: 10,
              focusScale: 1.02,
              onTap: () => _exitSystemMode(),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  tr('tv.keyboard.cancel'),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
