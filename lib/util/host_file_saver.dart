import 'package:file_picker/file_picker.dart';

/// Desktop "Save As" dialog. Returns a host path or null if cancelled.
///
/// Does not write bytes — caller streams the guest file onto the path.
Future<String?> pickHostSaveFilePath({
  required String fileName,
  String dialogTitle = '另存为',
}) {
  return FilePicker.saveFile(dialogTitle: dialogTitle, fileName: fileName);
}

/// Desktop folder picker. Returns a host directory or null if cancelled.
Future<String?> pickHostDirectoryPath({String dialogTitle = '选择导出文件夹'}) {
  return FilePicker.getDirectoryPath(dialogTitle: dialogTitle);
}
