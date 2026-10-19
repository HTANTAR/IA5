// Lanzador portable de Linux Config Tool.
// Contiene embebidos app.ps1, la interfaz web, los scripts bash y las DLL SSH.
// Al ejecutarse los extrae en %LOCALAPPDATA%\LinuxConfigTool\<build> y arranca Windows PowerShell.
// Los datos (servidores guardados, historial) quedan junto al .exe => portable.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("Linux Config Tool")]
[assembly: AssemblyDescription("IP fija y acceso por grupos AD para servidores Linux")]
[assembly: AssemblyProduct("Linux Config Tool")]
[assembly: AssemblyCopyright("MIT")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

internal static class Program
{
    private const string Prefix = "lct/";

    private static int Main(string[] args)
    {
        try
        {
            Console.Title = "Linux Config Tool";
            Assembly asm = Assembly.GetExecutingAssembly();
            string exeDir = Path.GetDirectoryName(asm.Location);
            string build = ReadResourceText(asm, Prefix + "buildid").Trim();

            string root = ExtractAll(asm, build);
            string ps1 = Path.Combine(root, "app.ps1");

            string ps = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(ps)) ps = "powershell.exe";

            // Se ejecuta como scriptblock (no como archivo) para que no lo bloquee la ExecutionPolicy de la PC.
            string extra = string.Join(" ", Array.ConvertAll(args, QuotePs));
            string command = "& ([scriptblock]::Create([IO.File]::ReadAllText(" + QuotePs(ps1) + "))) -AppRoot " + QuotePs(root)
                + " -DataDir " + QuotePs(exeDir) + (extra.Length > 0 ? " " + extra : "");

            ProcessStartInfo psi = new ProcessStartInfo(ps,
                "-NoProfile -NoLogo -ExecutionPolicy Bypass -Command \"" + command.Replace("\"", "\\\"") + "\"");
            psi.UseShellExecute = false;
            psi.WorkingDirectory = root;
            using (Process p = Process.Start(psi))
            {
                p.WaitForExit();
                if (p.ExitCode != 0)
                {
                    Console.WriteLine();
                    Console.WriteLine("Linux Config Tool termino con codigo " + p.ExitCode + ". Presione Enter para cerrar.");
                    Console.ReadLine();
                }
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("No se pudo iniciar Linux Config Tool: " + ex.Message);
            Console.WriteLine("Presione Enter para cerrar.");
            Console.ReadLine();
            return 1;
        }
    }

    private static string QuotePs(string s)
    {
        return "'" + s.Replace("'", "''") + "'";
    }

    private static string ReadResourceText(Assembly asm, string name)
    {
        using (Stream s = asm.GetManifestResourceStream(name))
        {
            if (s == null) return "dev";
            using (StreamReader r = new StreamReader(s)) return r.ReadToEnd();
        }
    }

    private static string ExtractAll(Assembly asm, string build)
    {
        string[] bases = new string[] {
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Path.GetTempPath()
        };
        Exception last = null;
        foreach (string b in bases)
        {
            if (string.IsNullOrEmpty(b)) continue;
            string root = Path.Combine(Path.Combine(b, "LinuxConfigTool"), "app-" + build);
            try
            {
                string marker = Path.Combine(root, ".complete");
                if (File.Exists(marker)) return root;
                Directory.CreateDirectory(root);
                foreach (string name in asm.GetManifestResourceNames())
                {
                    if (!name.StartsWith(Prefix) || name == Prefix + "buildid") continue;
                    string rel = name.Substring(Prefix.Length).Replace('/', Path.DirectorySeparatorChar);
                    string dest = Path.Combine(root, rel);
                    Directory.CreateDirectory(Path.GetDirectoryName(dest));
                    using (Stream src = asm.GetManifestResourceStream(name))
                    using (FileStream fs = new FileStream(dest, FileMode.Create, FileAccess.Write))
                    {
                        byte[] buf = new byte[81920];
                        int n;
                        while ((n = src.Read(buf, 0, buf.Length)) > 0) fs.Write(buf, 0, n);
                    }
                }
                File.WriteAllText(marker, DateTime.Now.ToString("s"));
                return root;
            }
            catch (Exception ex)
            {
                last = ex;
            }
        }
        throw new IOException("No se pudieron extraer los archivos de la aplicacion: " + (last != null ? last.Message : ""));
    }
}
