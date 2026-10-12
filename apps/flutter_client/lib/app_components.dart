import 'package:flutter/material.dart';
import 'app_theme.dart';

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.caption});
  final String title;
  final String? caption;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(2, 20, 2, 10),
      child: Row(children: [
        Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.muted))),
        if (caption != null)
          Text(caption!,
              style: const TextStyle(fontSize: 11, color: AppTheme.subtle)),
      ]));
}

class ProfileInfoRow extends StatelessWidget {
  const ProfileInfoRow(this.label, this.value, {super.key});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 72,
            child: Text(label,
                style: const TextStyle(fontSize: 13, color: AppTheme.muted))),
        const SizedBox(width: 12),
        Expanded(
            child: SelectableText(value.isEmpty ? '未设置' : value,
                style: const TextStyle(fontSize: 14, color: AppTheme.text))),
      ]));
}

class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon(this.name, {super.key});
  final String name;
  @override
  Widget build(BuildContext context) {
    final extension = name.split('.').last.toLowerCase();
    var icon = Icons.insert_drive_file_outlined;
    var color = AppTheme.muted;
    if (const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp']
        .contains(extension)) {
      icon = Icons.image_outlined;
      color = AppTheme.accent;
    } else if (const ['mp4', 'mov', 'mkv', 'avi', 'webm'].contains(extension)) {
      icon = Icons.videocam_outlined;
      color = const Color(0xFF8564CE);
    } else if (const ['mp3', 'wav', 'aac', 'flac', 'm4a', 'ogg']
        .contains(extension)) {
      icon = Icons.music_note_outlined;
      color = AppTheme.success;
    } else if (const ['zip', 'rar', '7z', 'tar', 'gz'].contains(extension)) {
      icon = Icons.folder_zip_outlined;
      color = const Color(0xFFB68530);
    } else if (extension == 'pdf') {
      icon = Icons.description_outlined;
      color = AppTheme.danger;
    } else if (const ['doc', 'docx', 'txt', 'md', 'xls', 'xlsx', 'ppt', 'pptx']
        .contains(extension)) {
      icon = Icons.description_outlined;
      color = AppTheme.accent;
    }
    return Container(
        width: 40,
        height: 44,
        decoration: BoxDecoration(
            color: color.withValues(alpha: .08),
            borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, color: color, size: 23));
  }
}

String formatFileSize(int value) {
  var size = value < 0 ? 0.0 : value.toDouble();
  var unit = 0;
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final amount = unit == 0
      ? size.round().toString()
      : size.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  return '$amount ${units[unit]}';
}
