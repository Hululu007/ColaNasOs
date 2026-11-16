@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ==========================================================
echo  ColaNasOs TV 版面预览（网页版）
echo    Flutter Web  http://127.0.0.1:5175
echo    控制口        http://127.0.0.1:5176/status  token: colanas-tv-ctl
echo.
echo  键位：
echo    方向键        移动焦点（遥控器 D-pad）
echo    回车 / 空格   确认（遥控器 OK）
echo    Backspace / Esc  返回
echo.
echo  说明：TV 版面走独立入口 lib\main_tv.dart，dev.bat / 正式客户端
echo        的行为完全不变；只有本脚本会进入 TV 版面。
echo ==========================================================
echo.

if not exist "node_modules\electron\dist\electron.exe" (
  echo [x] 缺少依赖：请先执行  npm install
  pause
  exit /b 1
)

set "FLUTTER=flutter"
where flutter >nul 2>nul || set "FLUTTER=C:\dev\flutter\bin\flutter.bat"
if not "%FLUTTER%"=="flutter" if not exist "%FLUTTER%" (
  echo [x] 找不到 flutter：请把 TV.bat 里的 FLUTTER 改成你的 flutter 路径
  pause
  exit /b 1
)

REM TV 预览固定用开发内核（7888）：开发内核会按请求 origin 放行 CORS，
REM 而正式服务端 7788 是生产配置，不允许 5175 跨源调用 API（登录会静默失败）。
REM 7888 与正式版默认共用同一份数据目录，看到的就是真实媒体库。
set "API_PORT=7888"
call :probe 7888
if not errorlevel 1 (
  call :cors 7888
  if errorlevel 1 (
    echo [x] 7888 已被占用，但没有开启开发期 CORS。
    echo     5175 页面会被浏览器拦跨域，登录会静默失败。
    echo     请先关掉占用 7888 的进程，或改用 dev.bat 启动开发内核后再运行 TV.bat。
    pause
    exit /b 1
  )
)
if errorlevel 1 (
  echo [i] 7888 没有开发内核，启动一个（窗口保持打开）...
  set "COLANAS_DEV_TOKEN=1"
  set "COLANAS_JWT_SECRET=colanas-dev-only-secret-change-me"
  set "COLANAS_CTL_TOKEN=colanas-dev-ctl"
  set "COLANAS_DEV_INSTANCE=1"
  start "ColaNasOs Kernel (TV preview)" /D "%~dp0" cmd /k node tool\dev\watch-kernel.js
  echo [i] 等待开发内核就绪（首次需要编译，最多 90 秒）...
  call :wait 7888 90
  if errorlevel 1 echo [!] 内核还没就绪：预览页可以先打开，稍后在登录页重试连接。
) else (
  echo [i] 复用已有开发内核：http://127.0.0.1:7888
)
echo.

cd /d "%~dp0apps\colanas_os"
REM 控制口与 dev.bat（5174）分开，两边可以同时开，互不打断。
set "COLANAS_CTL_PORT=5176"
set "COLANAS_CTL_TOKEN=colanas-tv-ctl"
echo 启动 Flutter Web（TV 入口，首次编译约 30-60 秒）...
node "%~dp0tool\dev\flutter-dev.js" run -d chrome --web-port 5175 --web-browser-flag=--window-size=1600,900 --target lib/main_tv.dart --dart-define=COLANAS_TV=1 --dart-define=COLANAS_API_BASE=http://127.0.0.1:%API_PORT%
if errorlevel 1 (
  echo.
  echo [x] TV 预览启动失败。完整日志：.devdata\flutter-dev.log
  echo     常见原因：Flutter 参数写错 / 端口被占用 / 依赖未拉取（flutter pub get）
  pause
)
endlocal
exit /b 0

:probe
powershell -NoProfile -Command "try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 'http://127.0.0.1:%~1/health').StatusCode | Out-Null; exit 0 } catch { exit 1 }" >nul 2>nul
exit /b %ERRORLEVEL%

:cors
powershell -NoProfile -Command "try { $r=Invoke-WebRequest -UseBasicParsing -Method Options -TimeoutSec 1 -Headers @{Origin='http://localhost:5175'} 'http://127.0.0.1:%~1/health'; if ($r.Headers['Access-Control-Allow-Origin']) { exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>nul
exit /b %ERRORLEVEL%

:wait
for /L %%i in (1,1,%~2) do (
  call :probe %~1
  if not errorlevel 1 exit /b 0
  ping -n 2 127.0.0.1 >nul
)
exit /b 1
