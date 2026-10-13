import 'app_motion.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'api.dart';
import 'avatar_crop.dart';

const defaultAvatars = <String, String>{
  'cat': '默认头像 1',
  'dog': '默认头像 2',
  'fox': '默认头像 3',
  'rabbit': '默认头像 4',
  'bear': '默认头像 5',
  'panda': '默认头像 6',
  'penguin': '默认头像 7',
  'owl': '默认头像 8',
};
String normalizeAvatarId(String? id) =>
    id == 'custom' || defaultAvatars.containsKey(id) ? id! : 'cat';

class AvatarSelection {
  const AvatarSelection(this.id, {this.revision = '', this.image});
  final String id;
  final String revision;
  final Uint8List? image;
}

final avatarProfiles = ValueNotifier<Map<String, AvatarSelection>>({});
final _avatarImages = <String, Future<Uint8List>>{};
void rememberAvatar(String id, String? avatarId, {String revision = ''}) {
  final value = normalizeAvatarId(avatarId), old = avatarProfiles.value[id];
  if (old?.id == value && old?.revision == revision) return;
  avatarProfiles.value = {
    ...avatarProfiles.value,
    id: AvatarSelection(value, revision: revision)
  };
}

void clearAvatarProfiles() {
  avatarProfiles.value = {};
  _avatarImages.clear();
}

Future<Uint8List> _customImage(String peerId, String revision) {
  final key = '$peerId:$revision';
  return _avatarImages.putIfAbsent(key, () {
    if (_avatarImages.length > 64) {
      _avatarImages.remove(_avatarImages.keys.first);
    }
    return api.social(
        'avatar-image', {'peerId': peerId, 'revision': revision}).then((value) {
      final image = value['image'] as String;
      if (image.length > 410000 ||
          !image.startsWith('data:image/png;base64,')) {
        throw Exception('头像图片无效');
      }
      return base64Decode(image.substring('data:image/png;base64,'.length));
    }).catchError((Object error) {
      _avatarImages.remove(key);
      throw error;
    });
  });
}

class AccountAvatar extends StatelessWidget {
  const AccountAvatar(
      {super.key,
      this.avatarId,
      this.accountId,
      this.revision = '',
      this.image,
      this.preferCurrent = false,
      this.size = 46,
      this.online});
  final String? avatarId;
  final String? accountId;
  final String revision;
  final Uint8List? image;
  final bool preferCurrent;
  final double size;
  final bool? online;
  Widget _photo(AvatarSelection value) {
    final fallback = Image.asset(
        'assets/avatars/${value.id == 'custom' ? 'cat' : normalizeAvatarId(value.id)}.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        excludeFromSemantics: true);
    Widget memory(Uint8List bytes) => Image.memory(bytes,
        width: size,
        height: size,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        errorBuilder: (_, __, ___) => fallback);
    if (image != null) return memory(image!);
    if (value.id == 'custom' &&
        accountId != null &&
        value.revision.isNotEmpty) {
      return FutureBuilder<Uint8List>(
          future: _customImage(accountId!, value.revision),
          builder: (_, snapshot) =>
              snapshot.hasData ? memory(snapshot.data!) : fallback);
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<String, AvatarSelection>>(
          valueListenable: avatarProfiles,
          builder: (context, profiles, _) =>
              Stack(clipBehavior: Clip.none, children: [
                ClipRRect(
                    borderRadius: BorderRadius.circular(size * .28),
                    child: _photo(
                        (preferCurrent ? null : profiles[accountId]) ??
                            AvatarSelection(normalizeAvatarId(avatarId),
                                revision: revision))),
                if (online != null)
                  Positioned(
                      right: -2,
                      bottom: -2,
                      child: Semantics(
                          label: online! ? '在线' : '离线',
                          image: true,
                          child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: online!
                                      ? const Color(0xFF21A67A)
                                      : const Color(0xFF98A2B3),
                                  border: Border.all(
                                      color: Colors.white, width: 2))))),
              ]));
}

typedef AvatarSaver = Future<AvatarSelection> Function(AvatarSelection avatar);
Future<AvatarSelection?> chooseAccountAvatar(BuildContext context,
        {required AvatarSelection current,
        String? accountId,
        AvatarSaver? save}) =>
    showModalBottomSheet<AvatarSelection>(
        context: context,
        sheetAnimationStyle: AppMotion.style(context),
        isScrollControlled: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 460),
        builder: (_) => AvatarPicker(
            current: current,
            accountId: accountId,
            save: save ??
                (selected) async {
                  final result = await api.social('avatar', {
                    'avatarId': selected.id,
                    if (selected.image != null)
                      'image':
                          'data:image/png;base64,${base64Encode(selected.image!)}'
                  });
                  return AvatarSelection(result['avatarId'],
                      revision: result['avatarRevision'] ?? '');
                }));

class AvatarPicker extends StatefulWidget {
  const AvatarPicker(
      {super.key, required this.current, required this.save, this.accountId});
  final AvatarSelection current;
  final AvatarSaver save;
  final String? accountId;
  @override
  State<AvatarPicker> createState() => _AvatarPickerState();
}

class _AvatarPickerState extends State<AvatarPicker> {
  late AvatarSelection _selected = widget.current;
  bool _saving = false, _picking = false;
  String? _error;
  Future<void> _selectPhoto() async {
    setState(() => _picking = true);
    try {
      final file = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 2048,
          maxHeight: 2048,
          imageQuality: 95,
          requestFullMetadata: false);
      if (file == null || !mounted) return;
      if (await file.length() > 8 * 1024 * 1024) {
        throw Exception('图片过大，请选择 8 MB 以内的图片');
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final cropped = await cropAvatarPhoto(context, bytes);
      if (cropped != null && mounted) {
        setState(() => _selected = AvatarSelection('custom', image: cropped));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '无法读取图片：$error');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await widget.save(_selected);
      if (mounted) Navigator.pop(context, result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_saving && !_picking,
      child: SafeArea(
          top: false,
          child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('更换头像',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                const SizedBox(height: 24),
                AccountAvatar(
                    avatarId: _selected.id,
                    accountId:
                        _selected.image == null && _selected.id == 'custom'
                            ? widget.accountId
                            : null,
                    revision: _selected.revision,
                    image: _selected.image,
                    size: 88),
                const SizedBox(height: 8),
                TextButton.icon(
                    onPressed: _saving || _picking ? null : _selectPhoto,
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: Text(_picking ? '正在选图…' : '从图片选择')),
                const SizedBox(height: 16),
                GridView(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            mainAxisExtent: 78,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12),
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      if (widget.current.id == 'custom')
                        _option(widget.current, '当前头像'),
                      ...defaultAvatars.entries
                          .map((e) => _option(AvatarSelection(e.key), e.value)),
                    ]),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!,
                          style: const TextStyle(
                              color: Colors.red, fontSize: 12))),
                const SizedBox(height: 20),
                SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                        onPressed: _saving || _picking ? null : _save,
                        child: Text(_saving ? '保存中…' : '保存头像'))),
              ]))));
  Widget _option(AvatarSelection value, String label) {
    final selected = _selected.id == value.id && _selected.image == value.image;
    return Semantics(
        label: label,
        button: true,
        selected: selected,
        child: InkWell(
            onTap: _saving || _picking
                ? null
                : () => setState(() => _selected = value),
            borderRadius: BorderRadius.circular(20),
            child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        width: 2,
                        color: selected
                            ? const Color(0xFF3D7FFF)
                            : Colors.transparent)),
                child: Stack(children: [
                  Positioned.fill(
                      child: AccountAvatar(
                          avatarId: value.id,
                          accountId:
                              value.id == 'custom' ? widget.accountId : null,
                          revision: value.revision,
                          image: value.image,
                          size: 64)),
                  if (selected)
                    Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                                color: const Color(0xFF3D7FFF),
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.white, width: 2)),
                            child: const Icon(Icons.check,
                                size: 12, color: Colors.white))),
                ]))));
  }
}
