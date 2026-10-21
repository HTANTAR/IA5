// Helper SSH para Linux Config Tool.
// Se compila en tiempo de ejecucion con Add-Type (Windows PowerShell 5.1 => C# 5, sin sintaxis moderna).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Microsoft.Win32;
using Renci.SshNet;
using Renci.SshNet.Common;

namespace Lct
{
    public class RunResult
    {
        public bool Ok { get; set; }
        public int ExitCode { get; set; }
        public string Output { get; set; }
        public string ErrorKind { get; set; }
        public string ErrorMessage { get; set; }
        public string HostKey { get; set; }
        public string Transfer { get; set; }
    }

    public static class Ssh
    {
        private static ConnectionInfo BuildInfo(string host, int port, string user, string pass, int connectTimeoutSec)
        {
            PasswordAuthenticationMethod pw = new PasswordAuthenticationMethod(user, pass);
            KeyboardInteractiveAuthenticationMethod kb = new KeyboardInteractiveAuthenticationMethod(user);
            kb.AuthenticationPrompt += delegate(object sender, AuthenticationPromptEventArgs e)
            {
                foreach (AuthenticationPrompt p in e.Prompts) { p.Response = pass; }
            };
            ConnectionInfo ci = new ConnectionInfo(host, port, user, pw, kb);
            ci.Timeout = TimeSpan.FromSeconds(connectTimeoutSec);
            return ci;
        }

        private static string Exec(SshClient c, string cmd, int timeoutSec, out int exitCode)
        {
            using (SshCommand sc = c.CreateCommand(cmd))
            {
                sc.CommandTimeout = TimeSpan.FromSeconds(timeoutSec);
                string outp = sc.Execute();
                string err = sc.Error;
                exitCode = sc.ExitStatus;
                if (!string.IsNullOrEmpty(err)) { outp = (outp ?? "") + err; }
                return outp ?? "";
            }
        }

        // Ejecuta un script bash en el servidor remoto.
        // asRoot=true: lo ejecuta como root (directo si el usuario ya es root, si no con sudo usando la misma contrasena).
        // La contrasena viaja por SFTP a un archivo temporal con permisos 600 que se borra antes de invocar sudo,
        // asi no queda visible en la lista de procesos del servidor.
        public static RunResult Run(string host, int port, string user, string pass, string script, bool asRoot, int timeoutSec)
        {
            RunResult r = new RunResult();
            r.Output = "";
            string fingerprint = null;
            try
            {
                ConnectionInfo ci = BuildInfo(host, port, user, pass, 15);
                using (SshClient c = new SshClient(ci))
                {
                    c.HostKeyReceived += delegate(object s, HostKeyEventArgs e)
                    {
                        fingerprint = e.HostKeyName + " " + BitConverter.ToString(e.FingerPrint).Replace("-", ":").ToLowerInvariant();
                        e.CanTrust = true;
                    };
                    c.Connect();
                    r.HostKey = fingerprint;

                    int rc;
                    string dir = Exec(c, "/bin/sh -c 'umask 077; mktemp -d /tmp/.lct.XXXXXXXX'", 30, out rc).Trim();
                    if (rc != 0 || !dir.StartsWith("/tmp/.lct."))
                    {
                        r.ErrorKind = "remote";
                        r.ErrorMessage = "No se pudo crear un directorio temporal en el servidor: " + dir;
                        return r;
                    }

                    byte[] jobBytes = new UTF8Encoding(false).GetBytes(script.Replace("\r\n", "\n").Replace("\r", "\n"));
                    byte[] pwBytes = new UTF8Encoding(false).GetBytes(pass + "\n");

                    bool uploaded = false;
                    try
                    {
                        using (SftpClient sftp = new SftpClient(ci))
                        {
                            sftp.Connect();
                            using (MemoryStream ms = new MemoryStream(jobBytes)) { sftp.UploadFile(ms, dir + "/job.sh"); }
                            using (MemoryStream ms = new MemoryStream(pwBytes)) { sftp.UploadFile(ms, dir + "/pw"); }
                            sftp.Disconnect();
                        }
                        uploaded = true;
                        r.Transfer = "sftp";
                    }
                    catch (Exception)
                    {
                        uploaded = false;
                    }

                    if (!uploaded)
                    {
                        // Alternativa si el servidor no tiene SFTP habilitado.
                        Exec(c, "/bin/sh -c 'umask 077; printf %s " + Convert.ToBase64String(jobBytes) + " | base64 -d > " + dir + "/job.sh'", 60, out rc);
                        Exec(c, "/bin/sh -c 'umask 077; printf %s " + Convert.ToBase64String(pwBytes) + " | base64 -d > " + dir + "/pw'", 60, out rc);
                        r.Transfer = "base64";
                    }

                    string runPart = asRoot
                        ? "if [ \"$(id -u)\" = 0 ]; then bash job.sh </dev/null; rc=$?; else sudo -S -p \"\" bash job.sh <&3; rc=$?; fi"
                        : "bash job.sh </dev/null; rc=$?";
                    string payload = "exec 2>&1; D=" + dir + "; cd \"$D\" || exit 97; exec 3<pw; rm -f pw; "
                        + runPart + "; exec 3<&-; cd /; rm -rf \"$D\"; exit $rc";
                    string cmd = "/bin/sh -c '" + payload.Replace("'", "'\\''") + "'";

                    int exitCode;
                    r.Output = Exec(c, cmd, timeoutSec, out exitCode);
                    r.ExitCode = exitCode;
                    r.Ok = true;
                    c.Disconnect();
                }
            }
            catch (SshAuthenticationException ex)
            {
                r.ErrorKind = "auth";
                r.ErrorMessage = "Usuario o contrasena incorrectos (" + ex.Message + ")";
            }
            catch (SocketException ex)
            {
                r.ErrorKind = "network";
                r.ErrorMessage = "No se pudo conectar al servidor: " + ex.Message;
            }
            catch (SshOperationTimeoutException ex)
            {
                r.ErrorKind = "timeout";
                r.ErrorMessage = "Tiempo de espera agotado: " + ex.Message;
            }
            catch (SshConnectionException ex)
            {
                r.ErrorKind = "network";
                r.ErrorMessage = "Error de conexion SSH: " + ex.Message;
            }
            catch (Exception ex)
            {
                r.ErrorKind = "error";
                r.ErrorMessage = ex.GetType().Name + ": " + ex.Message;
            }
            if (r.HostKey == null) { r.HostKey = fingerprint; }
            return r;
        }

        // Sube archivos locales de esta PC al servidor (SFTP; si no hay SFTP, SCP).
        public static UploadResult Upload(string host, int port, string user, string pass, string[] localPaths, string remoteDir)
        {
            UploadResult r = new UploadResult();
            List<string> done = new List<string>();
            try
            {
                if (localPaths == null || localPaths.Length == 0) { r.ErrorMessage = "No hay archivos para subir."; return r; }
                foreach (string lp in localPaths)
                {
                    if (!File.Exists(lp)) { r.ErrorMessage = "No existe el archivo: " + lp; return r; }
                }
                ConnectionInfo ci = BuildInfo(host, port, user, pass, 15);
                bool sftpOk = false;
                try
                {
                    using (SftpClient sftp = new SftpClient(ci))
                    {
                        sftp.OperationTimeout = TimeSpan.FromMinutes(10);
                        sftp.Connect();
                        string acc = "";
                        foreach (string part in remoteDir.Split('/'))
                        {
                            if (part.Length == 0) continue;
                            acc += "/" + part;
                            if (!sftp.Exists(acc)) sftp.CreateDirectory(acc);
                        }
                        foreach (string lp in localPaths)
                        {
                            string dest = remoteDir.TrimEnd('/') + "/" + Path.GetFileName(lp);
                            using (FileStream fs = File.OpenRead(lp)) { sftp.UploadFile(fs, dest, true); }
                            done.Add(dest);
                        }
                        sftp.Disconnect();
                        sftpOk = true;
                        r.Transfer = "sftp";
                    }
                }
                catch (Exception)
                {
                    sftpOk = false;
                }
                if (!sftpOk)
                {
                    done.Clear();
                    using (SshClient c = new SshClient(ci))
                    {
                        c.Connect();
                        int rc;
                        Exec(c, "mkdir -p '" + remoteDir.Replace("'", "") + "'", 30, out rc);
                        c.Disconnect();
                    }
                    using (ScpClient scp = new ScpClient(ci))
                    {
                        scp.OperationTimeout = TimeSpan.FromMinutes(10);
                        scp.Connect();
                        foreach (string lp in localPaths)
                        {
                            string dest = remoteDir.TrimEnd('/') + "/" + Path.GetFileName(lp);
                            using (FileStream fs = File.OpenRead(lp)) { scp.Upload(fs, dest); }
                            done.Add(dest);
                        }
                        scp.Disconnect();
                        r.Transfer = "scp";
                    }
                }
                r.Ok = true;
            }
            catch (SshAuthenticationException) { r.ErrorMessage = "Usuario o contrasena incorrectos."; }
            catch (Exception ex) { r.ErrorMessage = ex.GetType().Name + ": " + ex.Message; }
            r.Remote = done.ToArray();
            return r;
        }

        // Devuelve true si el puerto TCP responde (para esperar a que el servidor aparezca con la IP nueva).
        public static bool Probe(string host, int port, int timeoutMs)
        {
            try
            {
                using (TcpClient tc = new TcpClient())
                {
                    IAsyncResult ar = tc.BeginConnect(host, port, null, null);
                    bool ok = ar.AsyncWaitHandle.WaitOne(timeoutMs);
                    if (!ok) { return false; }
                    tc.EndConnect(ar);
                    return tc.Connected;
                }
            }
            catch (Exception)
            {
                return false;
            }
        }
    }

    // Ventana de lectura sobre otro stream (para recorrer un .tar dentro de otro .tar sin copiarlo)
    public class SubStream : Stream
    {
        private readonly Stream inner; private long left; private readonly byte[] peek = new byte[2]; private int peekLen = 0, peekPos = 0;
        public SubStream(Stream inner, long length) { this.inner = inner; this.left = length; }
        public int PeekByte(int i)
        {
            while (peekLen <= i && left > 0) { int b = inner.ReadByte(); if (b < 0) break; peek[peekLen++] = (byte)b; left--; }
            return i < peekLen ? peek[i] : -1;
        }
        public override int Read(byte[] buffer, int offset, int count)
        {
            if (peekPos < peekLen) { int n = 0; while (peekPos < peekLen && count > 0) { buffer[offset++] = peek[peekPos++]; count--; n++; } return n; }
            if (left <= 0) return 0;
            int k = inner.Read(buffer, offset, (int)Math.Min(count, left));
            if (k > 0) left -= k;
            return k;
        }
        public void SkipRest() { peekPos = peekLen; byte[] b = new byte[65536]; while (left > 0) { int k = inner.Read(b, 0, (int)Math.Min(b.Length, left)); if (k <= 0) break; left -= k; } }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
        public override void Flush() { }
        public override long Seek(long o, SeekOrigin so) { throw new NotSupportedException(); }
        public override void SetLength(long v) { throw new NotSupportedException(); }
        public override void Write(byte[] b, int o, int c) { throw new NotSupportedException(); }
    }

    public class UploadResult
    {
        public bool Ok { get; set; }
        public string ErrorMessage { get; set; }
        public string Transfer { get; set; }
        public string[] Remote { get; set; }
    }

    public class SasPackages
    {
        public string[] Files { get; set; }
        public string Client { get; set; }
        public string GroupPolicy { get; set; }
        public string Error { get; set; }
        public string[] Others { get; set; }
        public string License { get; set; }      // archivo de licencia .dlv (si hay)
        public string FromArchive { get; set; }  // .tar del que se extrajeron los paquetes
    }

    public static class Files
    {
        // Busca vasclnt / vasgp (Safeguard Authentication Services) en una carpeta (y subcarpetas).
        // kind: deb | rpm ; arch: salida de "uname -m" del servidor (x86_64, aarch64...)
        public static SasPackages FindSasPackages(string folder, string kind, string arch)
        {
            SasPackages r = new SasPackages();
            r.Files = new string[0]; r.Others = new string[0];
            if (string.IsNullOrEmpty(folder)) { r.Error = "Elegi la carpeta o el archivo .tar del instalador."; return r; }
            folder = folder.Trim().Trim('"');
            string ext = kind == "rpm" ? ".rpm" : ".deb";
            string a = (arch ?? "x86_64").ToLowerInvariant();
            string[] archNames = (a == "aarch64" || a == "arm64") ? new string[] { "arm64", "aarch64" }
                               : (a == "x86_64" || a == "amd64") ? new string[] { "amd64", "x86_64" }
                               : new string[] { a };
            string searchDir = folder;
            List<string> tars = new List<string>();
            if (File.Exists(folder))
            {
                if (!IsArchive(folder)) { r.Error = "El archivo elegido no es un .tar / .tar.gz / .tgz: " + folder; return r; }
                tars.Add(folder);
                searchDir = null;
            }
            else if (!Directory.Exists(folder)) { r.Error = "La carpeta no existe o no se puede abrir: " + folder; return r; }

            List<string> all = new List<string>();
            if (searchDir != null) Collect(searchDir, ext, all, 0);
            string clnt = Pick(all, "vasclnt", archNames);
            // Sin paquetes sueltos: buscar dentro de los .tar de la carpeta (hasta 1 nivel)
            if (clnt == null && searchDir != null)
            {
                try
                {
                    foreach (string f in Directory.GetFiles(searchDir)) if (IsArchive(f)) tars.Add(f);
                    foreach (string d in Directory.GetDirectories(searchDir))
                        try { foreach (string f in Directory.GetFiles(d)) if (IsArchive(f)) tars.Add(f); } catch (Exception) { }
                }
                catch (Exception) { }
            }
            List<string> seen = new List<string>();
            foreach (string tar in tars)
            {
                if (clnt != null) break;
                try
                {
                    string cache = ExtractSasFromArchive(tar, ext, archNames, seen);
                    List<string> got = new List<string>();
                    Collect(cache, ext, got, 0);
                    string c2 = Pick(got, "vasclnt", archNames);
                    if (c2 != null) { all = got; clnt = c2; r.FromArchive = tar; }
                }
                catch (Exception ex) { seen.Add("(" + Path.GetFileName(tar) + ": " + ex.Message + ")"); }
            }
            string gp = Pick(all, "vasgp", archNames);
            List<string> files = new List<string>();
            if (clnt != null) files.Add(clnt);
            if (gp != null) files.Add(gp);
            r.Client = clnt; r.GroupPolicy = gp; r.Files = files.ToArray();
            List<string> others = new List<string>();
            foreach (string f in all) { string n = Path.GetFileName(f).ToLowerInvariant(); if (n.StartsWith("vas") && !files.Contains(f) && others.Count < 15) others.Add(f); }
            foreach (string sname in seen) if (others.Count < 25) others.Add(sname);
            r.Others = others.ToArray();
            // Licencia: .dlv en la carpeta elegida o junto al .tar
            string licDir = searchDir ?? Path.GetDirectoryName(folder);
            if (r.FromArchive != null && searchDir == null) licDir = Path.GetDirectoryName(r.FromArchive);
            try
            {
                if (licDir != null && Directory.Exists(licDir))
                {
                    string[] lic = Directory.GetFiles(licDir, "*.dlv");
                    if (lic.Length > 0) { Array.Sort(lic); r.License = lic[lic.Length - 1]; }
                }
            }
            catch (Exception) { }
            if (clnt == null) r.Error = "No encontre el paquete vasclnt (" + ext + ", " + string.Join("/", archNames) + ") en " + folder + (tars.Count > 0 ? " (revise " + tars.Count + " archivo(s) .tar)" : "");
            return r;
        }

        private static bool IsArchive(string f)
        {
            string n = f.ToLowerInvariant();
            return n.EndsWith(".tar") || n.EndsWith(".tar.gz") || n.EndsWith(".tgz");
        }

        // Extrae del .tar solo vasclnt / vasgp de la extension y arquitectura pedidas. Devuelve la carpeta de cache.
        public static string ExtractSasFromArchive(string archive, string ext, string[] archNames, List<string> seen)
        {
            FileInfo fi = new FileInfo(archive);
            string baseDir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (string.IsNullOrEmpty(baseDir)) baseDir = Path.GetTempPath();
            string key = System.Text.RegularExpressions.Regex.Replace(Path.GetFileName(archive), "[^A-Za-z0-9._-]", "_") + "-" + fi.Length + "-" + ext.TrimStart('.') + "-" + archNames[0];
            string cache = Path.Combine(Path.Combine(Path.Combine(baseDir, "LinuxConfigTool"), "sas"), key);
            string marker = Path.Combine(cache, ".done");
            if (File.Exists(marker)) return cache;
            if (Directory.Exists(cache)) { try { Directory.Delete(cache, true); } catch (Exception) { } }
            Directory.CreateDirectory(cache);
            using (FileStream fs = File.OpenRead(archive))
            {
                TarScan(OpenMaybeGzip(fs), cache, ext, archNames, seen, 0);
            }
            File.WriteAllText(marker, DateTime.Now.ToString("s"));
            return cache;
        }

        private static Stream OpenMaybeGzip(Stream s)
        {
            BufferedStream bs = new BufferedStream(s, 1 << 16);
            int b1 = bs.ReadByte(), b2 = bs.ReadByte();
            bs.Seek(0, SeekOrigin.Begin);
            if (b1 == 0x1f && b2 == 0x8b) return new GZipStream(bs, CompressionMode.Decompress);
            return bs;
        }

        private static bool Wanted(string name, string ext, string[] archNames)
        {
            string n = name.ToLowerInvariant();
            if (!n.EndsWith(ext)) return false;
            if (!(n.StartsWith("vasclnt_") || n.StartsWith("vasclnt-") || n.StartsWith("vasgp_") || n.StartsWith("vasgp-"))) return false;
            string rest = n.Substring(n.StartsWith("vasgp") ? 6 : 8);
            if (rest.Length == 0 || !char.IsDigit(rest[0])) return false;
            foreach (string an in archNames) if (n.Contains(an)) return true;
            return n.Contains("noarch") || n.Contains("_all.");
        }

        private static long ParseOctal(byte[] h, int off, int len)
        {
            // GNU base-256 para tamanos grandes
            if ((h[off] & 0x80) != 0) { long v = 0; for (int i = 1; i < len; i++) v = (v << 8) | h[off + i]; return v; }
            long r = 0;
            for (int i = off; i < off + len; i++)
            {
                byte c = h[i];
                if (c == 0 || c == 32) { if (r > 0) break; else continue; }
                if (c < '0' || c > '7') break;
                r = r * 8 + (c - '0');
            }
            return r;
        }

        private static string CStr(byte[] h, int off, int len)
        {
            int end = off;
            while (end < off + len && h[end] != 0) end++;
            return Encoding.UTF8.GetString(h, off, end - off);
        }

        private static void ReadFully(Stream s, byte[] buf, int len)
        {
            int got = 0;
            while (got < len) { int n = s.Read(buf, got, len - got); if (n <= 0) throw new EndOfStreamException("tar truncado"); got += n; }
        }

        private static void Skip(Stream s, long n)
        {
            byte[] buf = new byte[65536];
            while (n > 0) { int k = s.Read(buf, 0, (int)Math.Min(buf.Length, n)); if (k <= 0) throw new EndOfStreamException("tar truncado"); n -= k; }
        }

        private static void TarScan(Stream s, string outDir, string ext, string[] archNames, List<string> seen, int depth)
        {
            byte[] h = new byte[512];
            string longName = null;
            while (true)
            {
                int got = 0;
                while (got < 512) { int n = s.Read(h, got, 512 - got); if (n <= 0) break; got += n; }
                if (got < 512) return;
                bool zero = true;
                for (int i = 0; i < 512; i++) if (h[i] != 0) { zero = false; break; }
                if (zero) return;
                string name = CStr(h, 0, 100);
                string prefix = CStr(h, 345, 155);
                if (prefix.Length > 0 && CStr(h, 257, 6).StartsWith("ustar")) name = prefix + "/" + name;
                long size = ParseOctal(h, 124, 12);
                char type = (char)h[156];
                long padded = (size + 511) / 512 * 512;
                if (type == 'L')
                {
                    byte[] nb = new byte[size]; ReadFully(s, nb, (int)size); Skip(s, padded - size);
                    longName = Encoding.UTF8.GetString(nb).TrimEnd('\0'); continue;
                }
                if (type == 'x' || type == 'g')
                {
                    byte[] pb = new byte[size]; ReadFully(s, pb, (int)size); Skip(s, padded - size);
                    if (type == 'x')
                    {
                        string pax = Encoding.UTF8.GetString(pb);
                        foreach (string line in pax.Split('\n'))
                        {
                            int sp = line.IndexOf(' ');
                            if (sp > 0 && line.Substring(sp + 1).StartsWith("path=")) longName = line.Substring(sp + 6);
                        }
                    }
                    continue;
                }
                if (longName != null) { name = longName; longName = null; }
                string fileName = name.Replace('\\', '/');
                fileName = fileName.Substring(fileName.LastIndexOf('/') + 1);
                bool isFile = type == '0' || type == '\0' || type == '7';
                if (isFile && Wanted(fileName, ext, archNames))
                {
                    string dest = Path.Combine(outDir, fileName);
                    using (FileStream o = File.Create(dest))
                    {
                        byte[] buf = new byte[65536]; long left = size;
                        while (left > 0) { int k = s.Read(buf, 0, (int)Math.Min(buf.Length, left)); if (k <= 0) throw new EndOfStreamException("tar truncado"); o.Write(buf, 0, k); left -= k; }
                    }
                    Skip(s, padded - size);
                }
                else if (isFile && depth == 0 && IsArchive(fileName) && size > 0)
                {
                    // tar anidado (ej. un .tar.gz por plataforma): se recorre sin extraerlo entero
                    SubStream sub = new SubStream(s, size);
                    try { TarScan(OpenMaybeGzipNoSeek(sub), outDir, ext, archNames, seen, depth + 1); } catch (Exception ex) { seen.Add("(" + fileName + ": " + ex.Message + ")"); }
                    sub.SkipRest();
                    Skip(s, padded - size);
                }
                else
                {
                    if (isFile && fileName.ToLowerInvariant().StartsWith("vas") && seen.Count < 40) seen.Add(name);
                    Skip(s, padded);
                }
            }
        }

        private static Stream OpenMaybeGzipNoSeek(SubStream sub)
        {
            int b1 = sub.PeekByte(0), b2 = sub.PeekByte(1);
            if (b1 == 0x1f && b2 == 0x8b) return new GZipStream(sub, CompressionMode.Decompress, true);
            return sub;
        }

        private static void Collect(string dir, string ext, List<string> acc, int depth)
        {
            if (depth > 6 || acc.Count > 2000) return;
            try
            {
                foreach (string f in Directory.GetFiles(dir, "*" + ext))
                {
                    if (Path.GetFileName(f).StartsWith("vas", StringComparison.OrdinalIgnoreCase)) acc.Add(f);
                }
                foreach (string d in Directory.GetDirectories(dir)) Collect(d, ext, acc, depth + 1);
            }
            catch (Exception) { }
        }

        private static string Pick(List<string> all, string name, string[] archNames)
        {
            string best = null;
            foreach (string f in all)
            {
                string n = Path.GetFileName(f).ToLowerInvariant();
                if (!(n.StartsWith(name + "_") || n.StartsWith(name + "-"))) continue;
                string rest = n.Substring(name.Length + 1);
                if (rest.Length == 0 || !char.IsDigit(rest[0])) continue;   // vasclnts, vasclnt-devel, etc.
                bool archOk = false;
                foreach (string an in archNames) { if (n.Contains(an)) { archOk = true; break; } }
                if (!archOk && !n.Contains("noarch") && !n.Contains("_all.")) continue;
                if (best == null || string.CompareOrdinal(n, Path.GetFileName(best).ToLowerInvariant()) > 0) best = f;
            }
            return best;
        }
    }

    // ---------------- Diagnostico de proxy desde esta PC ----------------
    public class ProbeResult
    {
        public string Target { get; set; }
        public string Mode { get; set; }        // proxy | proxy-windows | system
        public string Via { get; set; }         // proxy realmente usado ("" = directo)
        public int Code { get; set; }
        public string Status { get; set; }
        public string Error { get; set; }
        public string ProxyAuth { get; set; }   // esquemas que ofrece el proxy en el 407 (Basic, NTLM, Negotiate)
        public string CertIssuer { get; set; }
        public string CertRoot { get; set; }
        public string SslErrors { get; set; }
        public bool Blocked { get; set; }       // 403 generado por el proxy (no por el sitio)
        public long Ms { get; set; }
    }

    public class PcProxyInfo
    {
        public string UserName { get; set; }
        public string ForHttp { get; set; }
        public string ForHttps { get; set; }
        public bool ManualEnabled { get; set; }
        public string ManualServer { get; set; }
        public string AutoConfigUrl { get; set; }
        public string Suggested { get; set; }
    }

    public class ProxyTestResult
    {
        public PcProxyInfo Pc { get; set; }
        public ProbeResult[] Results { get; set; }
    }

    public static class NetDiag
    {
        static NetDiag()
        {
            try { ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072 | (SecurityProtocolType)768; } catch (Exception) { }
        }

        private static string Describe(IWebProxy sys, string url)
        {
            try
            {
                Uri u = new Uri(url);
                if (sys == null || sys.IsBypassed(u)) return "";
                Uri p = sys.GetProxy(u);
                if (p == null || p.Equals(u) || p.Host == u.Host) return "";
                return p.Scheme + "://" + p.Authority;
            }
            catch (Exception) { return ""; }
        }

        // "http=p1:8080;https=p2:8080" o "p:8080" -> "http://p:8080"
        private static string FromManual(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            string pick = s.Trim();
            foreach (string part in s.Split(';'))
            {
                string x = part.Trim();
                if (x.StartsWith("https=", StringComparison.OrdinalIgnoreCase)) { pick = x.Substring(6); break; }
                if (x.StartsWith("http=", StringComparison.OrdinalIgnoreCase)) { pick = x.Substring(5); }
            }
            if (pick.Contains("=")) pick = pick.Substring(pick.IndexOf('=') + 1);
            if (pick.Length == 0) return "";
            return pick.Contains("://") ? pick : "http://" + pick;
        }

        public static PcProxyInfo GetPcProxy()
        {
            PcProxyInfo info = new PcProxyInfo();
            info.UserName = Environment.UserDomainName + "\\" + Environment.UserName;
            try
            {
                IWebProxy sys = WebRequest.GetSystemWebProxy();
                info.ForHttp = Describe(sys, "http://archive.ubuntu.com/");
                info.ForHttps = Describe(sys, "https://cdn.redhat.com/");
            }
            catch (Exception) { }
            if (Environment.OSVersion.Platform == PlatformID.Win32NT)
            {
                try
                {
                    using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings"))
                    {
                        if (k != null)
                        {
                            object pe = k.GetValue("ProxyEnable");
                            info.ManualEnabled = pe is int && (int)pe == 1;
                            info.ManualServer = k.GetValue("ProxyServer") as string;
                            info.AutoConfigUrl = k.GetValue("AutoConfigURL") as string;
                        }
                    }
                }
                catch (Exception) { }
            }
            if (!string.IsNullOrEmpty(info.ForHttp)) info.Suggested = info.ForHttp;
            else if (!string.IsNullOrEmpty(info.ForHttps)) info.Suggested = info.ForHttps;
            else if (info.ManualEnabled) info.Suggested = FromManual(info.ManualServer);
            else info.Suggested = "";
            return info;
        }

        // mode: "proxy" (anonimo o con usuario:clave de la URL), "proxy-windows" (credenciales de Windows), "system" (como navega esta PC)
        public static ProbeResult Probe(string target, string mode, string proxyUrl, int timeoutMs)
        {
            ProbeResult r = new ProbeResult();
            r.Target = target; r.Mode = mode; r.Via = ""; r.Status = ""; r.Error = ""; r.ProxyAuth = "";
            Stopwatch sw = Stopwatch.StartNew();
            string issuer = null, root = null, sslErr = null;
            try
            {
                Uri tu = new Uri(target);
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(tu);
                req.Method = "GET";
                req.AllowAutoRedirect = false;
                req.KeepAlive = false;
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.UserAgent = "LinuxConfigTool/1.0";
                req.ConnectionGroupName = Guid.NewGuid().ToString("N");
                if (mode == "system")
                {
                    IWebProxy sys = WebRequest.GetSystemWebProxy();
                    sys.Credentials = CredentialCache.DefaultCredentials;
                    req.Proxy = sys;
                    r.Via = Describe(sys, target);
                }
                else
                {
                    Uri pu = new Uri(proxyUrl);
                    WebProxy wp = new WebProxy(pu.Scheme + "://" + pu.Host + ":" + pu.Port + "/");
                    wp.BypassProxyOnLocal = false;
                    if (!string.IsNullOrEmpty(pu.UserInfo))
                    {
                        string[] ui = Uri.UnescapeDataString(pu.UserInfo).Split(new char[] { ':' }, 2);
                        wp.Credentials = new NetworkCredential(ui[0], ui.Length > 1 ? ui[1] : "");
                    }
                    else if (mode == "proxy-windows")
                    {
                        wp.UseDefaultCredentials = true;
                    }
                    else
                    {
                        wp.UseDefaultCredentials = false;
                        wp.Credentials = null;
                    }
                    req.Proxy = wp;
                    r.Via = pu.Scheme + "://" + pu.Host + ":" + pu.Port;
                }
                req.ServerCertificateValidationCallback = delegate(object s, X509Certificate cert, X509Chain chain, SslPolicyErrors errs)
                {
                    try
                    {
                        if (cert != null) issuer = cert.Issuer;
                        if (chain != null && chain.ChainElements.Count > 0) root = chain.ChainElements[chain.ChainElements.Count - 1].Certificate.Subject;
                        if (errs != SslPolicyErrors.None) sslErr = errs.ToString();
                    }
                    catch (Exception) { }
                    return true; // solo diagnostico: no se envian datos
                };
                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                {
                    r.Code = (int)resp.StatusCode;
                }
            }
            catch (WebException ex)
            {
                HttpWebResponse hr = ex.Response as HttpWebResponse;
                if (hr != null)
                {
                    r.Code = (int)hr.StatusCode;
                    if (r.Code == 403)
                    {
                        string all = (hr.Headers["Server"] ?? "") + " " + (hr.Headers["X-Squid-Error"] ?? "") + " " + (hr.Headers["Proxy-Status"] ?? "")
                            + " " + (hr.Headers["X-BlueCoat-Via"] ?? "") + " " + (hr.Headers["X-Zscaler-Error"] ?? "");
                        string low = all.ToLowerInvariant();
                        foreach (string k in new string[] { "squid", "err_", "bluecoat", "proxysg", "zscaler", "mcafee", "webwasher", "forcepoint", "websense", "fortigate", "ironport", "skyhigh", "error=" })
                        {
                            if (low.Contains(k)) { r.Blocked = true; break; }
                        }
                    }
                    string[] pa = hr.Headers.GetValues("Proxy-Authenticate");
                    if (pa != null)
                    {
                        List<string> schemes = new List<string>();
                        foreach (string v in pa)
                        {
                            foreach (string piece in v.Split(','))
                            {
                                string w = piece.Trim().Split(' ')[0];
                                if (w.Length > 0 && !w.Contains("=") && !schemes.Contains(w)) schemes.Add(w);
                            }
                        }
                        r.ProxyAuth = string.Join(",", schemes.ToArray());
                    }
                    hr.Close();
                }
                else
                {
                    r.Status = ex.Status.ToString();
                    r.Error = ex.InnerException != null ? ex.InnerException.Message : ex.Message;
                }
            }
            catch (Exception ex)
            {
                r.Status = "Error";
                r.Error = ex.Message;
            }
            r.Ms = sw.ElapsedMilliseconds;
            r.CertIssuer = issuer;
            r.CertRoot = root;
            r.SslErrors = sslErr;
            return r;
        }

        public static ProxyTestResult Test(string proxyUrl, string[] targets, int timeoutMs)
        {
            ProxyTestResult res = new ProxyTestResult();
            res.Pc = GetPcProxy();
            List<ProbeResult> list = new List<ProbeResult>();
            if (targets == null || targets.Length == 0) targets = new string[] { "http://archive.ubuntu.com/" };
            if (timeoutMs <= 0) timeoutMs = 8000;
            bool hasCreds = false;
            try { hasCreds = !string.IsNullOrEmpty(new Uri(proxyUrl).UserInfo); } catch (Exception) { }
            foreach (string t in targets)
            {
                if (string.IsNullOrEmpty(t)) continue;
                ProbeResult a = Probe(t, "proxy", proxyUrl, timeoutMs);
                list.Add(a);
                if (a.Code == 407 && !hasCreds) list.Add(Probe(t, "proxy-windows", proxyUrl, timeoutMs));
                list.Add(Probe(t, "system", null, timeoutMs));
            }
            res.Results = list.ToArray();
            return res;
        }
    }
}
