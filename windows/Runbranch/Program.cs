// Runbranch — run any branch of any project on a real port.
// Copyright (C) 2026 Alec McLeod
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; without even the
// implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// See the GNU General Public License for more details:
// <https://www.gnu.org/licenses/>.

// Where a launch begins, before any XAML exists.
//
// One instance, as on the Mac, where the app is a single `Window` scene rather
// than a WindowGroup: a second window over the same projects would show the
// same state twice with no way to tell them apart. A second launch — the
// Start menu, a pinned taskbar icon, double-clicking the exe again — hands its
// activation to the running instance, which brings its window forward, and
// then exits without drawing anything.

using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Runbranch;

public static class Program
{
    /// <summary>
    /// Per user, not per machine: AppInstance keys are scoped to the user's
    /// session already, so two people signed in each get their own.
    ///
    /// And per copy of the app: the folder it runs from is part of the key.
    /// With one key for every copy, a development build left running from
    /// windows\Runbranch\bin captured every launch of the installed one and
    /// swallowed it — no window, no error. Two copies are two apps, as a
    /// development build and the installed one are on the Mac; launching the
    /// same copy twice still brings the first one forward.
    /// </summary>
    static readonly string InstanceKey = "Runbranch.main." + Convert.ToHexString(
        System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(AppContext.BaseDirectory.TrimEnd('\\').ToLowerInvariant())))[..16];

    [STAThread]
    static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();

        if (RedirectedToExisting()) return 0;

        Application.Start(_ignored =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        return 0;
    }

    static bool RedirectedToExisting()
    {
        var key = AppInstance.FindOrRegisterForKey(InstanceKey);
        if (key.IsCurrent)
        {
            key.Activated += (_, _) => App.Instance?.OnActivatedAgain();
            return false;
        }

        // This process was started by the user, so it may give the foreground
        // away; the running instance could not take it on its own, and its
        // window would only flash on the taskbar.
        AllowSetForegroundWindow((int)key.ProcessId);

        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        // Off this thread: the redirect is a cross-process call, and waiting
        // for it on an STA thread that is not pumping messages can deadlock.
        //
        // Bounded. The instance that holds the key may be hung — a crashed
        // run that Windows will not let anyone end still owns it until the
        // user signs out — and an unbounded wait here made every later launch
        // sit invisibly behind it, with nothing on screen to say why. A hung
        // instance cannot show a window anyway, so after a few seconds this
        // one opens on its own, without the key: a second instance is the
        // lesser failure when the first cannot answer.
        //
        // And a redirect that fails outright — the other instance exited
        // between being found and being called — opens this one too. Main has
        // no crash handler yet, so a throw here was a launch that did nothing
        // at all, with nothing in crash.log to say why.
        var redirect = Task.Run(() => key.RedirectActivationToAsync(activation).AsTask());
        try
        {
            return redirect.Wait(TimeSpan.FromSeconds(5));
        }
        catch (AggregateException)
        {
            return false;
        }
    }

    [DllImport("user32.dll")]
    static extern bool AllowSetForegroundWindow(int processId);
}
