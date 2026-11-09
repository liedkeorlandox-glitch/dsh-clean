import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

/// Storage maintenance is entirely local. It neither starts nor calls DSH,
/// and works with the engine stopped or uninstalled.
class StorageCleanerPage extends StatefulWidget {
  const StorageCleanerPage({super.key});

  @override
  State<StorageCleanerPage> createState() => _StorageCleanerPageState();
}

class _StorageCleanerPageState extends State<StorageCleanerPage> {
  static const _channel = MethodChannel('dsh/storage_cleaner');
  bool _busy = false;
  String? _error;
  Map<String, Object?> _summary = const {};
  List<Map<String, Object?>> _trash = const [];
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? e.code);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final summary = await _call<Map<Object?, Object?>>('scan');
    final trash = await _call<List<Object?>>('quarantineList');
    if (!mounted) return;
    setState(() {
      if (summary != null) _summary = summary.cast<String, Object?>();
      if (trash != null) {
        _trash = trash.whereType<Map<Object?, Object?>>().map((e) => e.cast<String, Object?>()).toList();
      }
      _selected.clear();
    });
  }

  Future<void> _quarantine() async {
    final zh = Localizations.localeOf(context).languageCode != 'en';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(zh ? '移入隔离区？' : 'Move to quarantine?'),
        content: Text(zh
            ? '仅处理已勾选的缓存。此操作不会释放空间，可在下方恢复。'
            : 'Only selected caches move. Space is freed only after purge; you can restore them below.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(zh ? '取消' : 'Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(zh ? '隔离' : 'Quarantine')),
        ],
      ),
    );
    if (ok != true) return;
    final result = await _call<Map<Object?, Object?>>('quarantine', {'paths': _selected.toList()});
    if (result != null) await _refresh();
  }

  Future<void> _purge() async {
    final zh = Localizations.localeOf(context).languageCode != 'en';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(zh ? '彻底删除满期项？' : 'Purge expired items?'),
        content: Text(zh
            ? '隔离满 1 天的项目将被永久删除，无法恢复。'
            : 'Items quarantined for at least one day will be permanently deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(zh ? '取消' : 'Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(zh ? '删除' : 'Delete')),
        ],
      ),
    );
    if (ok == true) {
      await _call('purge', {'olderThanMs': 86400000});
      await _refresh();
    }
  }

  String _bytes(Object? value) {
    final n = (value as num?)?.toDouble() ?? 0;
    if (n >= 1024 * 1024 * 1024) return '${(n / 1073741824).toStringAsFixed(1)} GB';
    if (n >= 1024 * 1024) return '${(n / 1048576).toStringAsFixed(1)} MB';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    return '$n B';
  }

  @override
  Widget build(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode != 'en';
    final categories =
        (_summary['categories'] as List<Object?>? ?? const []).whereType<Map<Object?, Object?>>().toList();
    return AppPage.list(
      title: zh ? '存储清理' : 'Storage cleaner',
      children: [
        SettingsSection(
          footer: Text(zh
              ? '完全在本机运行，不调用 AI、不启动引擎。只处理可重建缓存；会话、附件、插件和工作区永不扫描。'
              : 'Runs entirely on-device without AI or the engine. Only rebuildable caches are considered; chats, attachments, plugins and workspace are never scanned.'),
          children: [
            SettingsTile(
              title: zh ? '可隔离缓存' : 'Cache to quarantine',
              subtitle: Text(_bytes(_summary['totalBytes'])),
              trailing: _busy
                  ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              onTap: _busy ? null : _refresh,
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        SettingsSection(title: zh ? '缓存分类' : 'Cache categories', children: [
          for (final raw in categories)
            Builder(builder: (context) {
              final item = raw.cast<String, Object?>();
              final path = item['path'] as String? ?? '';
              return CheckboxListTile(
                value: _selected.contains(path),
                onChanged: _busy
                    ? null
                    : (v) => setState(() => v == true ? _selected.add(path) : _selected.remove(path)),
                title: Text('${item['id']} · ${_bytes(item['bytes'])}'),
                subtitle: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
                controlAffinity: ListTileControlAffinity.leading,
              );
            }),
          if (categories.isEmpty) ListTile(title: Text(zh ? '没有可清理的缓存' : 'No cleanable cache found')),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed: _busy || _selected.isEmpty ? null : _quarantine,
            icon: const Icon(Icons.archive_outlined),
            label: Text(zh ? '隔离已选缓存' : 'Quarantine selected'),
          ),
        ),
        SettingsSection(
          title: zh ? '隔离区' : 'Quarantine',
          footer: Text(zh ? '隔离 ≠ 释放。满 1 天的项目才能彻底删除。' : 'Quarantine does not free space. Items must age one day before purge.'),
          children: [
            for (final item in _trash)
              ListTile(
                title: Text(item['path'] as String? ?? ''),
                subtitle: Text(_bytes(item['bytes'])),
                trailing: TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          await _call('restore', {'id': item['id']});
                          await _refresh();
                        },
                  child: Text(zh ? '恢复' : 'Restore'),
                ),
              ),
            if (_trash.isEmpty) ListTile(title: Text(zh ? '隔离区为空' : 'Quarantine is empty')),
            ListTile(
              title: Text(zh ? '清理满期项目' : 'Purge expired items'),
              trailing: Text(_bytes(_summary['quarantineBytes'])),
              onTap: _busy || _trash.isEmpty ? null : _purge,
            ),
          ],
        ),
        const SizedBox(height: 72),
      ],
    );
  }
}
