using System.Text.Json;

namespace Cage.Windows;

// The hot input path sends data, not a new script (and unused script result)
// for every key/composition event. Keep the DOM event contract shared with
// the other native hosts and the existing request/reply protocol unchanged.
internal static class NativeBridge
{
    internal static string InputMessage(Dictionary<string, object?> value) =>
        JsonSerializer.Serialize(new { type = "cage-native-input", detail = value });

    internal const string Script = """
        (() => {
          if (window !== window.top || location.protocol !== 'http:' || location.hostname !== 'localhost') return;
          window.cageNativeIMEAvailable = true;
          const pending = new Map();
          const fileActions = new Set([
            'uploadHostFiles', 'chooseUploadFiles', 'clipboardSyncRead', 'clipboardSyncWrite',
            'saveBrowserDownload', 'browserDownloadAction', 'desktopFileAction', 'exportDiagnostics',
            'importTheme', 'exportTheme', 'shareLocalProject', 'chooseFolder', 'chooseGuestMedia',
          ]);
          chrome.webview.addEventListener('message', ({data}) => {
            if (!data || typeof data !== 'object') return;
            if (data.type === 'cage-native-input') {
              if (data.detail && typeof data.detail === 'object')
                window.dispatchEvent(new CustomEvent('cage-native-input', {detail: data.detail}));
              return;
            }
            const item = pending.get(data.id); if (!item) return;
            pending.delete(data.id); clearTimeout(item.timer);
            data.error ? item.reject(new Error(data.error)) : item.resolve(data.result);
          });
          const cage = {postMessage(request) { return new Promise((resolve, reject) => {
            const id = crypto.randomUUID();
            // File commands have a 30-minute backend deadline. Leave time for
            // the native file dialog and the final subprocess response.
            const timer = setTimeout(() => { pending.delete(id); reject(new Error('原生操作超时，请重试')); }, fileActions.has(request.action) ? 3600000 : 240000);
            pending.set(id, {resolve, reject, timer}); chrome.webview.postMessage({id, request});
          }); }};
          Object.defineProperty(window, 'webkit', {value: {messageHandlers: {cage}}, writable: false});
        })();
        """;
}
