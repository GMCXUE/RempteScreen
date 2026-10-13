import 'dart:io';
import 'package:sqflite/sqflite.dart';

String chatError(Object error) {
  if (error is DatabaseException) return '无法读取或保存本地聊天记录，请检查可用存储空间';
  if (error is FileSystemException) return '无法读取或保存聊天备份，请检查存储空间和文件权限';
  if (error is FormatException) return error.message.toString();
  return error.toString();
}
