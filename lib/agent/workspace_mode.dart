enum WorkspaceMode {
  chat,
  dev;

  String get id => name;

  static WorkspaceMode parse(String? raw) =>
      raw == 'dev' ? WorkspaceMode.dev : WorkspaceMode.chat;
}
