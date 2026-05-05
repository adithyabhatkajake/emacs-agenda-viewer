# Emacs Agenda Viewer

The goal of this project is to build a things 3 like front end for emacs agenda using emacs-client backend.

## Deploy

- Use `./deploy.sh` from the project root to build, deploy, and relaunch
- It builds the macOS app, kills existing instances, copies to ~/Applications, reloads eav.el in Emacs, restarts the server via launchd, and launches the app

## Server

- The EAV server runs via a launchd plist at `~/Library/LaunchAgents/com.hermitsage.emacs-agenda-viewer.plist`
- Restart with: `launchctl kickstart -k gui/$(id -u)/com.hermitsage.emacs-agenda-viewer`
- Logs at: `~/Library/Logs/emacs-agenda-viewer.log`
- Runs `npx tsx server/index.ts` from the project root on port 3001
