/// Minimal host environment for WSL processes.
///
/// Avoids passing the long Windows PATH into distros with automount disabled.
const wslHostEnvironment = {
  'PATH': r'C:\Windows\System32;C:\Windows',
  'SystemRoot': r'C:\Windows',
  'WINDIR': r'C:\Windows',
};
