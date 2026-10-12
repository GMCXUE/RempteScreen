import 'account_feedback.dart';
import 'package:flutter/material.dart';
import 'api.dart';
import 'account_avatar.dart';
import 'app_components.dart';
import 'app_theme.dart';

String genderLabel(String value) => value == 'male'
    ? '男'
    : value == 'female'
        ? '女'
        : '未设置';

class AccountProfileScreen extends StatefulWidget {
  const AccountProfileScreen({super.key, required this.account});
  final Account account;
  @override
  State<AccountProfileScreen> createState() => _AccountProfileScreenState();
}

class _AccountProfileScreenState extends State<AccountProfileScreen> {
  late Account _account = widget.account;
  late final _name = TextEditingController(text: _account.name),
      _bio = TextEditingController(text: _account.bio),
      _region = TextEditingController(text: _account.region);
  late String _gender = _account.gender, _birthday = _account.birthday;
  final _form = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _region.dispose();
    super.dispose();
  }

  Future<void> _avatar() async {
    final result = await chooseAccountAvatar(context,
        accountId: _account.id,
        current: avatarProfiles.value[_account.id] ??
            AvatarSelection(_account.avatarId,
                revision: _account.avatarRevision));
    if (result != null && mounted) {
      rememberAvatar(_account.id, result.id, revision: result.revision);
      showAccountFeedback(context, '头像已更新');
      try {
        final account = await api.me();
        if (mounted) setState(() => _account = account);
      } catch (_) {}
    }
  }

  Future<void> _date() async {
    final selected = await showDatePicker(
        context: context,
        initialDate: DateTime.tryParse(_birthday) ?? DateTime(2000),
        firstDate: DateTime(1900),
        lastDate: DateTime.now());
    if (selected != null && mounted) {
      setState(() => _birthday =
          '${selected.year.toString().padLeft(4, '0')}-${selected.month.toString().padLeft(2, '0')}-${selected.day.toString().padLeft(2, '0')}');
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await api.social('account-profile', {
        'name': _name.text.trim(),
        'bio': _bio.text.trim(),
        'region': _region.text.trim(),
        'gender': _gender,
        'birthday': _birthday
      });
      if (mounted) Navigator.pop(context, Account.fromJson(result['user']));
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
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(title: const Text('个人资料')),
        body: Form(
            key: _form,
            child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  Center(
                      child: Column(children: [
                    AccountAvatar(
                        accountId: _account.id,
                        avatarId: _account.avatarId,
                        revision: _account.avatarRevision,
                        size: 72),
                    TextButton(
                        onPressed: _saving ? null : _avatar,
                        child: const Text('更换头像'))
                  ])),
                  const SectionHeading('基本资料'),
                  TextFormField(
                      controller: _name,
                      enabled: !_saving,
                      maxLength: 32,
                      decoration: const InputDecoration(labelText: '昵称'),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? '请填写昵称'
                              : null),
                  const SizedBox(height: 14),
                  TextFormField(
                      controller: _bio,
                      enabled: !_saving,
                      maxLength: 160,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                          labelText: '个人简介', hintText: '介绍一下自己')),
                  const SectionHeading('更多资料'),
                  DropdownButtonFormField<String>(
                      initialValue: _gender,
                      decoration: const InputDecoration(labelText: '性别'),
                      items: const [
                        DropdownMenuItem(value: '', child: Text('不设置')),
                        DropdownMenuItem(value: 'male', child: Text('男')),
                        DropdownMenuItem(value: 'female', child: Text('女'))
                      ],
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _gender = value ?? '')),
                  const SizedBox(height: 14),
                  Card(
                      child: ListTile(
                          title: const Text('生日'),
                          subtitle: Text(_birthday.isEmpty ? '未设置' : _birthday),
                          onTap: _saving ? null : _date,
                          trailing: _birthday.isEmpty
                              ? const Icon(Icons.chevron_right)
                              : IconButton(
                                  tooltip: '清除生日',
                                  onPressed: _saving
                                      ? null
                                      : () => setState(() => _birthday = ''),
                                  icon: const Icon(Icons.close, size: 18)))),
                  const SizedBox(height: 14),
                  TextFormField(
                      controller: _region,
                      enabled: !_saving,
                      maxLength: 32,
                      decoration: const InputDecoration(
                          labelText: '地区', hintText: '可填写城市或地区')),
                  const SectionHeading('账号信息'),
                  Card(
                      child: Column(children: [
                    ProfileInfoRow('账号 ID', _account.accountId),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ProfileInfoRow('邮箱', _account.email)
                  ])),
                  const SizedBox(height: 14),
                  const Text('昵称和个人资料会显示在好友资料中，生日、性别、地区可以留空。',
                      style: TextStyle(fontSize: 12, color: AppTheme.muted)),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_error!,
                            style: const TextStyle(color: Colors.red))),
                ])),
        bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? '保存中…' : '保存资料')))),
      ));
}

class FriendProfileScreen extends StatelessWidget {
  const FriendProfileScreen({super.key, required this.friend});
  final Map<String, dynamic> friend;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('好友资料')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Center(
            child: AccountAvatar(
                accountId: friend['id'],
                avatarId: friend['avatarId'],
                revision: friend['avatarRevision'] ?? '',
                size: 72)),
        const SizedBox(height: 16),
        Center(
            child: Text(friend['name'] ?? '',
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w600))),
        const SizedBox(height: 24),
        Card(
            child: Column(children: [
          for (final entry in {
            '账号 ID': friend['accountId'],
            '个人简介': friend['bio'],
            '性别': genderLabel(friend['gender'] ?? ''),
            '生日': friend['birthday'],
            '地区': friend['region']
          }.entries)
            ProfileInfoRow(entry.key, entry.value?.toString() ?? ''),
        ])),
      ]));
}
