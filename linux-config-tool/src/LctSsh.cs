// Helper SSH para Linux Config Tool.
// Se compila en tiempo de ejecucion con Add-Type (Windows PowerShell 5.1 => C# 5, sin sintaxis moderna).
using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
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
}
