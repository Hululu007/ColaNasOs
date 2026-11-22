; 服务端安装包的自定义钩子（由 electron-builder 的 nsis.include 引入，见 electron-builder.js）。
;
; 目的：升级时自动关掉正在运行的服务端，用户不用先手动退出再装。
;
; electron-builder 自带的 CHECK_APP_RUNNING 会先弹一个「应用正在运行，是否关闭」
; 的确认框，而且只按进程名匹配 —— 对便携版 / 开发态的同一个可执行文件会误杀。
; 这里用 customCheckAppRunning 覆盖掉它，改成按「可执行文件路径在安装目录下」
; 精确匹配、静默结束进程。

!include "LogicLib.nsh"

!define COLANAS_PS "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"

; 结束所有从 $INSTDIR 启动的进程。
;
; 为什么连 transmission-daemon.exe 一起收：
; 内置的下载器是 detached 常驻进程（见 src/modules/pt/daemon.ts），
; 它占着 resources\transmission-daemon\ 下的 exe 与 DLL。只关外壳不动它，
; 下一步覆盖文件就会撞上「正在使用」，安装可能直接失败。
;
; 为什么只能强杀：服务端没有窗口，进程里也没有能响应 WM_CLOSE 的顶层窗口，
; taskkill 不带 /F 对它无效。
!macro COLANAS_STOP_APP
  DetailPrint "正在关闭已运行的服务端..."
  nsExec::Exec `"${COLANAS_PS}" -NoProfile -NonInteractive -Command "Get-CimInstance Win32_Process | Where-Object { $$_.ExecutablePath -and $$_.ExecutablePath.StartsWith('$INSTDIR', 'CurrentCultureIgnoreCase') } | ForEach-Object { Stop-Process -Id $$_.ProcessId -Force -ErrorAction SilentlyContinue }"`
  Pop $0
  ${If} $0 != 0
    ; PowerShell 不可用（极老系统 / 被策略禁用）时退化：按进程名强杀
    nsExec::Exec 'taskkill /F /IM "${APP_EXECUTABLE_FILENAME}" /T'
    Pop $0
    nsExec::Exec 'taskkill /F /IM "transmission-daemon.exe" /T'
    Pop $0
  ${EndIf}
  ; 给系统一点时间交出文件句柄，紧接着就是覆盖写
  Sleep 800
!macroend

!macro customCheckAppRunning
  !insertmacro COLANAS_STOP_APP
!macroend

; 手动卸载（非静默）时 electron-builder 不会检测进程，这里补上，
; 否则安装目录里的文件被占用，卸载删不干净。
!macro customUnInit
  !insertmacro COLANAS_STOP_APP
!macroend

; 全量安装包必须让内核跟随安装包。
;
; 拆壳后内核住在 <dataDir>\versions\D<ver>，由 current.json 指向；重装只覆盖
; 安装目录，指针不动 —— 结果就是「装了 1.3.22 还在跑 1.3.21 的内核」。
; 安装结束时删掉指针，外壳下次启动会从本安装包重新播种，直接指向这一版内核。
!macro customInstall
  DetailPrint "重置内核版本指针（下次启动跟随本安装包）..."
  Delete "$APPDATA\colanas_os_server\versions\current.json"
!macroend
