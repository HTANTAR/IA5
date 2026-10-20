// Helper SSH para Linux Config Tool.
// Se compila en tiempo de ejecucion con Add-Type (Windows PowerShell 5.1 => C# 5, sin sintaxis moderna).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
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
