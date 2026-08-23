import 'package:flutter/material.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:provider/provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:safenotes/data/preference_and_config.dart';
import 'package:safenotes/models/app_theme.dart';
import 'package:safenotes/models/theme_seeds.g.dart';
import 'package:safenotes/utils/editor_text.dart';
import 'package:safenotes/utils/platform_ui.dart';
import 'package:safenotes/utils/styles.dart';
import 'package:safenotes/views/settings/editor_font_setting.dart';
import 'package:safenotes/views/settings/font_settings_page.dart';
import 'package:safenotes/views/settings/theme_setting.dart';
import 'package:safenotes/widgets/shad_settings_tiles.dart';

class AppearanceSettingsPage extends StatefulWidget {
  const AppearanceSettingsPage({super.key});

  @override
  State<AppearanceSettingsPage> createState() => _AppearanceSettingsPageState();
}

class _AppearanceSettingsPageState extends State<AppearanceSettingsPage> {
  late bool _isCompactPreview;
  late bool _isMarkdownEnabled;
  late bool _isMarkdownToolbarEnabled;
  late bool _isRelativeTime;
  late bool _isSortByModified;

  late String _themeColorName;
  late String _notesColorValue;

  @override
  void initState() {
    super.initState();
    _loadSwitchValues();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadDisplayValues();
  }

  void _loadSwitchValues() {
    _isCompactPreview = PreferencesStorage.isCompactPreview;
    _isMarkdownEnabled = PreferencesStorage.isMarkdownEnabled;
    _isMarkdownToolbarEnabled = PreferencesStorage.isMarkdownToolbarEnabled;
    _isRelativeTime = PreferencesStorage.isRelativeTime;
    _isSortByModified = PreferencesStorage.isSortByModified;
  }

  void _loadDisplayValues() {
    _themeColorName = _currentThemeColorName(context);
    _notesColorValue = PreferencesStorage.isColorful ? 'On'.tr() : 'Off'.tr();
  }

  void _refresh() => setState(_loadDisplayValues);

  @override
  Widget build(BuildContext context) {
    Provider.of<ThemeProvider>(context);
    return Scaffold(
      appBar: AppBar(title: Text('Appearance'.tr(), style: appBarTitle)),
      body: shadSettingsList([
        shadSectionTitle(context, 'Theme'.tr()),
        shadSettingsCard([
          shadNavigationTile(
            context,
            key: const Key('ui-setting-item-darkmode'),
            icon: LucideIcons.moon,
            title: 'Dark mode'.tr(),
            value: !PreferencesStorage.isThemeDark ? 'Off'.tr() : 'On'.tr(),
            onTap: () => showThemeBottomSheet(context),
          ),
          shadNavigationTile(
            context,
            key: const Key('ui-setting-item-themecolor'),
            icon: LucideIcons.paintbrush,
            title: 'Theme color'.tr(),
            value: _themeColorName,
            onTap: () async {
              await Navigator.pushNamed(context, '/themeColorSettings');
              _refresh();
            },
          ),
          shadNavigationTile(
            context,
            key: const Key('ui-setting-item-notescolor'),
            icon: LucideIcons.brush,
            title: 'Notes Color'.tr(),
            value: _notesColorValue,
            onTap: () async {
              await Navigator.pushNamed(context, '/chooseColorSettings');
              _refresh();
            },
          ),
          shadNavigationTile(
            context,
            key: const Key('ui-setting-item-fontsettings'),
            icon: LucideIcons.type,
            title: 'Font settings'.tr(),
            value: _globalFontTypeValue(),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FontSettingsPicker()),
              );
              _refresh();
            },
          ),
        ]),
        shadSectionTitle(context, 'Display'.tr()),
        shadSettingsCard([
          KeyedSubtree(
            key: const Key('ui-setting-switch-compact'),
            child: shadSwitchTile(
              context,
              icon: LucideIcons.shrink,
              title: 'Compact Notes'.tr(),
              value: _isCompactPreview,
              onChanged: (v) {
                PreferencesStorage.setIsCompactPreview(v);
                setState(() => _isCompactPreview = v);
              },
            ),
          ),
          KeyedSubtree(
            key: const Key('ui-setting-switch-markdown'),
            child: shadSwitchTile(
              context,
              icon: LucideIcons.type,
              title: 'Markdown'.tr(),
              description:
                  'Format note preview with Markdown. Off shows plain text.'
                      .tr(),
              value: _isMarkdownEnabled,
              onChanged: (v) {
                PreferencesStorage.setIsMarkdownEnabled(v);
                setState(() => _isMarkdownEnabled = v);
              },
            ),
          ),
          KeyedSubtree(
            key: const Key('ui-setting-switch-markdown-toolbar'),
            child: shadSwitchTile(
              context,
              icon: LucideIcons.panelBottom,
              title: 'Markdown Toolbar'.tr(),
              description:
                  'Show formatting toolbar and auto-indent in note editor.'
                      .tr(),
              value: _isMarkdownToolbarEnabled,
              onChanged: (v) {
                PreferencesStorage.setIsMarkdownToolbarEnabled(v);
                setState(() => _isMarkdownToolbarEnabled = v);
              },
            ),
          ),
          shadNavigationTile(
            context,
            key: const Key('ui-setting-item-notestyle'),
            icon: LucideIcons.type,
            title: 'Note style'.tr(),
            value: _noteStyleValue(),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NoteStylePicker()),
              );
              _refresh();
            },
          ),
          KeyedSubtree(
            key: const Key('ui-setting-switch-relativetime'),
            child: shadSwitchTile(
              context,
              icon: LucideIcons.clock,
              title: 'Relative Time'.tr(),
              description:
                  'Show note timestamps as relative (e.g. 5 minutes ago). Off shows absolute dates.'
                      .tr(),
              value: _isRelativeTime,
              onChanged: (v) {
                PreferencesStorage.setIsRelativeTime(v);
                setState(() => _isRelativeTime = v);
              },
            ),
          ),
          shadSwitchTile(
            context,
            icon: LucideIcons.arrowUpDown,
            title: 'Sort by Modified Date'.tr(),
            description:
                'Sort notes by last modified time. Off sorts by creation time.'
                    .tr(),
            value: _isSortByModified,
            onChanged: (v) {
              PreferencesStorage.setIsSortByModified(v);
              setState(() => _isSortByModified = v);
            },
          ),
        ]),
        const SizedBox(height: 12),
      ]),
    );
  }

  String _currentThemeColorName(BuildContext context) {
    final isZh = context.locale.languageCode == 'zh';
    final seed = AppThemeSeeds.itemByIndex(
      PreferencesStorage.themeGroupIndex,
      PreferencesStorage.themeColorIndex,
    );
    return isZh ? seed.name : seed.nameEn;
  }

  String _globalFontTypeValue() {
    final t =
        AppFontType.values[PreferencesStorage.fontFamilyTypeIndex.clamp(
          0,
          AppFontType.values.length - 1,
        )];
    return switch (t) {
      AppFontType.serif => 'Serif'.tr(),
      AppFontType.sans => 'Sans-serif'.tr(),
      AppFontType.mono => 'Monospace'.tr(),
    };
  }

  String _noteStyleValue() {
    final idx = PreferencesStorage.noteFontFamilyTypeIndex;
    final fontLabel = switch (idx) {
      0 => 'System'.tr(),
      1 => 'Sans-serif'.tr(),
      2 => 'Serif'.tr(),
      3 => 'Monospace'.tr(),
      _ => 'System'.tr(),
    };
    final sizeLabel = EditorText.labelOf(
      PreferencesStorage.editorFontSizeIndex,
    );
    return '$fontLabel · $sizeLabel';
  }
}
