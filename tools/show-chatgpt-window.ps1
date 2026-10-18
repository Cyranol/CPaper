[CmdletBinding()]
param([Parameter(Mandatory=$true)][int]$ProcessId)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential)]
public struct PropertyKey {
    public Guid FormatId;
    public uint PropertyId;
}

[StructLayout(LayoutKind.Explicit, Size=24)]
public struct PropertyValue {
    [FieldOffset(0)] public ushort Type;
    [FieldOffset(8)] public IntPtr Text;
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IWindowPropertyStore {
    [PreserveSig] int GetCount(out uint count);
    [PreserveSig] int GetAt(uint index, out PropertyKey key);
    [PreserveSig] int GetValue(ref PropertyKey key, out PropertyValue value);
    [PreserveSig] int SetValue(ref PropertyKey key, ref PropertyValue value);
    [PreserveSig] int Commit();
}

public static class ChatGptWindow {
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr ignored);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr ignored);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int capacity);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int capacity);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("shell32.dll", PreserveSig=false)] private static extern void SHGetPropertyStoreForWindow(IntPtr window, ref Guid interfaceId, [MarshalAs(UnmanagedType.Interface)] out IWindowPropertyStore store);
    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropertyValue value);
    private static readonly Guid AppModelFormat = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    public static long FindMainWindow(uint processId) {
        IntPtr result = IntPtr.Zero;
        EnumWindows((window, ignored) => {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != processId) return true;
            var name = new StringBuilder(100);
            var title = new StringBuilder(100);
            GetClassName(window, name, name.Capacity);
            GetWindowText(window, title, title.Capacity);
            long style = GetWindowLongPtr(window, -16).ToInt64();
            // The main window is frameless; blank detached windows can still have WS_CAPTION.
            if (name.ToString() == "Chrome_WidgetWin_1" && title.ToString() == "ChatGPT" && (style & 0x00040000) != 0) {
                result = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result.ToInt64();
    }

    public static bool Show(long handle) {
        var window = new IntPtr(handle);
        // SW_SHOW preserves a maximized window; SW_RESTORE is only for minimized ones.
        ShowWindowAsync(window, IsIconic(window) ? 9 : 5);
        SetForegroundWindow(window);
        return IsWindowVisible(window) && !IsIconic(window);
    }

    public static bool IsShown(long handle) {
        var window = new IntPtr(handle);
        return IsWindowVisible(window) && !IsIconic(window);
    }

    public static string SetAppId(long handle, string appId) {
        Guid iid = typeof(IWindowPropertyStore).GUID;
        IWindowPropertyStore store;
        SHGetPropertyStoreForWindow(new IntPtr(handle), ref iid, out store);
        try {
            var key = new PropertyKey { FormatId = AppModelFormat, PropertyId = 5 };
            PropertyValue oldValue;
            int read = store.GetValue(ref key, out oldValue);
            string previous = read == 0 && oldValue.Type == 31 ? Marshal.PtrToStringUni(oldValue.Text) : "";
            if (read == 0) PropVariantClear(ref oldValue);
            if (previous == appId) return previous;
            var value = new PropertyValue { Type = 31, Text = Marshal.StringToCoTaskMemUni(appId) };
            try {
                Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
                Marshal.ThrowExceptionForHR(store.Commit());
            } finally { Marshal.FreeCoTaskMem(value.Text); }
            return previous;
        } finally { Marshal.ReleaseComObject(store); }
    }
}
'@

$window = 0
for ($attempt = 0; $attempt -lt 40; $attempt++) {
    $window = [ChatGptWindow]::FindMainWindow([uint32]$ProcessId)
    if ($window) { break }
    Start-Sleep -Milliseconds 150
}
if (-not $window) { throw 'The ChatGPT main window was not found.' }
$oldAppId = [ChatGptWindow]::SetAppId($window, 'OpenAI.Codex_2p2nqsd0c76g0!App')
$visible = [ChatGptWindow]::Show($window)
for ($attempt = 0; -not $visible -and $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 150
    $visible = [ChatGptWindow]::IsShown($window)
}
if (-not $visible) { throw 'The ChatGPT main window could not be restored.' }
[pscustomobject]@{ProcessId=$ProcessId;Window=$window;PreviousAppId=$oldAppId;Visible=$visible;TrayInvoked=$false} | ConvertTo-Json -Compress
