using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

internal static class StartupPresetManagerLauncher
{
    [STAThread]
    private static void Main()
    {
        try
        {
            var appDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "StartupPresetManager");
            Directory.CreateDirectory(appDirectory);

            var scriptPath = Path.Combine(appDirectory, "StartupPresetManager.runtime.ps1");
            using (var source = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream("StartupPresetManager.ps1"))
            {
                if (source == null)
                    throw new InvalidOperationException("The embedded application script could not be found.");

                using (var destination = new FileStream(scriptPath, FileMode.Create, FileAccess.Write, FileShare.Read))
                    source.CopyTo(destination);
            }

            var process = Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell\\v1.0\\powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File \"" + scriptPath + "\"",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = appDirectory
            });

            if (process == null)
                throw new InvalidOperationException("The application could not be started.\n");

            process.WaitForExit();
        }
        catch (Exception error)
        {
            System.Windows.Forms.MessageBox.Show(
                "Startup Preset Manager could not start.\n\n" + error.Message,
                "Startup Preset Manager",
                System.Windows.Forms.MessageBoxButtons.OK,
                System.Windows.Forms.MessageBoxIcon.Error);
        }
    }
}
