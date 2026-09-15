using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace MihomoControl;

public sealed class MainForm : Form
{
    private const string BaseDir = @"C:\Mihomo";
    private const string ScriptsDir = BaseDir + @"\scripts";
    private const string ModeFile = BaseDir + @"\mode.txt";
    private const string StateFile = BaseDir + @"\watchdog-state.json";
    private const string SubscriptionFile = BaseDir + @"\subscription.txt";
    private const string ConfigFile = BaseDir + @"\config.yaml";
    private const string TunConfigFile = BaseDir + @"\config.tun.yaml";
    private const string TemplateFile = BaseDir + @"\config.template.yaml";
    private const string MihomoExe = BaseDir + @"\mihomo.exe";
    private const string ValidationRoot = BaseDir + @"\temp\validation";
    private const string LatestReleaseApi = "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest";
    private const string CoreUpdateRoot = BaseDir + @"\temp\core-update";

    private readonly Label _modeValue = new();
    private readonly Label _processValue = new();
    private readonly Label _proxyValue = new();
    private readonly Label _nodeValue = new();
    private readonly Label _healthValue = new();
    private readonly Label _watchdogValue = new();
    private readonly Label _operationValue = new();
    private readonly Label _subscriptionInfo = new();

    private readonly Label _installedVersion = new();
    private readonly Label _latestVersion = new();
    private readonly Label _updateStatus = new();

    private readonly Button _proxyMode = new();
    private readonly Button _tunMode = new();
    private readonly Button _offMode = new();
    private readonly Button _restart = new();
    private readonly Button _refresh = new();
    private readonly Button _paste = new();
    private readonly Button _test = new();
    private readonly Button _apply = new();
    private readonly Button _updateNow = new();
    private readonly Button _checkCoreUpdate = new();
    private readonly Button _validateCandidate = new();
    private readonly Button _installValidated = new();
    private readonly Button _testRollback = new();
    private readonly Button _copyDiagnostics = new();
    private readonly Button _about = new();

    private string? _pendingText;
    private string? _validatedCandidatePath;
    private string? _validatedReleaseTag;
    private string? _validatedCandidateSha256;
    private bool _busy;
    private bool _statusRefreshRunning;
    private readonly System.Windows.Forms.Timer _statusTimer = new();
    private readonly NotifyIcon _trayIcon = new();
    private bool _exitRequested;

    public MainForm()
    {
        Text = "Mihomo Control";
        try
        {
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        }
        catch
        {
            // Icon is cosmetic; never prevent the control UI from starting.
        }

        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        ClientSize = new Size(760, 790);
        Font = new Font("Segoe UI", 10F);

        AddStatusRow("Mode", _modeValue, 40);
        AddStatusRow("Mihomo", _processValue, 70);
        AddStatusRow("System proxy", _proxyValue, 100);
        AddStatusRow("Active node", _nodeValue, 130);
        AddStatusRow("Health", _healthValue, 160);
        AddStatusRow("Watchdog", _watchdogValue, 195);

        var modeGroup = new GroupBox
        {
            Text = "Mode",
            Location = new Point(350, 35),
            Size = new Size(380, 120)
        };
        Controls.Add(modeGroup);

        ConfigureButton(_proxyMode, "Proxy", 20, 35, modeGroup, async (_, _) => await SwitchModeAsync("proxy"));
        ConfigureButton(_tunMode, "TUN", 135, 35, modeGroup, async (_, _) => await SwitchModeAsync("tun"));
        ConfigureButton(_offMode, "Off", 250, 35, modeGroup, async (_, _) => await SwitchModeAsync("off"));

        _restart.Text = "Restart Proxy";
        _restart.Size = new Size(150, 38);
        _restart.Location = new Point(365, 175);
        _restart.Click += async (_, _) => await RunScriptAsync("Start-Mihomo.ps1", false, "-Restart");
        Controls.Add(_restart);

        _refresh.Text = "Refresh";
        _refresh.Size = new Size(150, 38);
        _refresh.Location = new Point(530, 175);
        _refresh.Click += async (_, _) => await RefreshStateAsync();
        Controls.Add(_refresh);

        var subGroup = new GroupBox
        {
            Text = "Subscription / Config",
            Location = new Point(24, 245),
            Size = new Size(706, 170)
        };
        Controls.Add(subGroup);

        _subscriptionInfo.Text = "No pending import";
        _subscriptionInfo.AutoSize = false;
        _subscriptionInfo.Location = new Point(18, 32);
        _subscriptionInfo.Size = new Size(665, 45);
        subGroup.Controls.Add(_subscriptionInfo);

        ConfigureButton(_paste, "Paste", 18, 92, subGroup, (_, _) => PasteInput());
        ConfigureButton(_test, "Test", 138, 92, subGroup, async (_, _) => await TestPendingAsync());
        ConfigureButton(_apply, "Apply", 258, 92, subGroup, async (_, _) => await ApplyPendingAsync());
        ConfigureButton(_updateNow, "Update now", 378, 92, subGroup, async (_, _) => await UpdateProviderNowAsync());

        var coreGroup = new GroupBox
        {
            Text = "Mihomo Core — stable channel",
            Location = new Point(24, 435),
            Size = new Size(706, 225)
        };
        Controls.Add(coreGroup);

        var installedKey = new Label { Text = "Installed:", AutoSize = true, Location = new Point(18, 32) };
        _installedVersion.Text = "—";
        _installedVersion.AutoSize = true;
        _installedVersion.Font = new Font("Segoe UI Semibold", 10F);
        _installedVersion.Location = new Point(100, 32);

        var latestKey = new Label { Text = "Latest stable:", AutoSize = true, Location = new Point(18, 62) };
        _latestVersion.Text = "not checked";
        _latestVersion.AutoSize = true;
        _latestVersion.Font = new Font("Segoe UI Semibold", 10F);
        _latestVersion.Location = new Point(120, 62);

        _updateStatus.Text = "Run U2 validation before transactional U3 install";
        _updateStatus.AutoSize = false;
        _updateStatus.Size = new Size(495, 70);
        _updateStatus.Location = new Point(18, 94);

        _checkCoreUpdate.Text = "Check update";
        _checkCoreUpdate.Size = new Size(145, 38);
        _checkCoreUpdate.Location = new Point(535, 35);
        _checkCoreUpdate.Click += async (_, _) => await CheckCoreUpdateAsync();

        _validateCandidate.Text = "Download && validate";
        _validateCandidate.Size = new Size(145, 38);
        _validateCandidate.Location = new Point(535, 85);
        _validateCandidate.Click += async (_, _) => await ValidateLatestCandidateAsync();

        _installValidated.Text = "Install validated";
        _installValidated.Size = new Size(145, 38);
        _installValidated.Location = new Point(535, 135);
        _installValidated.Enabled = false;
        _installValidated.Click += async (_, _) => await InstallValidatedCandidateAsync(false);

        _testRollback.Text = "Test rollback";
        _testRollback.Size = new Size(145, 32);
        _testRollback.Location = new Point(535, 180);
        _testRollback.Enabled = false;
        _testRollback.Click += async (_, _) => await InstallValidatedCandidateAsync(true);

        coreGroup.Controls.Add(installedKey);
        coreGroup.Controls.Add(_installedVersion);
        coreGroup.Controls.Add(latestKey);
        coreGroup.Controls.Add(_latestVersion);
        coreGroup.Controls.Add(_updateStatus);
        coreGroup.Controls.Add(_checkCoreUpdate);
        coreGroup.Controls.Add(_validateCandidate);
        coreGroup.Controls.Add(_installValidated);
        coreGroup.Controls.Add(_testRollback);

        var diagGroup = new GroupBox
        {
            Text = "Diagnostics",
            Location = new Point(24, 655),
            Size = new Size(706, 70)
        };
        Controls.Add(diagGroup);

        _copyDiagnostics.Text = "Copy diagnostics";
        _copyDiagnostics.Size = new Size(160, 36);
        _copyDiagnostics.Location = new Point(18, 24);
        _copyDiagnostics.Click += async (_, _) => await CopyDiagnosticsAsync();
        diagGroup.Controls.Add(_copyDiagnostics);

        _about.Text = "About";
        _about.Size = new Size(90, 36);
        _about.Location = new Point(585, 24);
        _about.Click += async (_, _) => await ShowAboutAsync();
        diagGroup.Controls.Add(_about);

        var diagHint = new Label
        {
            Text = "Safe report for support",
            AutoSize = false,
            Location = new Point(195, 27),
            Size = new Size(360, 34)
        };
        diagGroup.Controls.Add(diagHint);

        _operationValue.Text = "Ready";
        _operationValue.AutoSize = true;
        _operationValue.Location = new Point(24, 745);
        Controls.Add(_operationValue);

        var trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add("Open", null, (_, _) => RestoreFromTray());
        trayMenu.Items.Add(new ToolStripSeparator());
        trayMenu.Items.Add("Proxy", null, async (_, _) => await SwitchModeAsync("proxy"));
        trayMenu.Items.Add("TUN", null, async (_, _) => await SwitchModeAsync("tun"));
        trayMenu.Items.Add("Off", null, async (_, _) => await SwitchModeAsync("off"));
        trayMenu.Items.Add(new ToolStripSeparator());
        trayMenu.Items.Add("Exit UI", null, (_, _) =>
        {
            _exitRequested = true;
            Close();
        });

        _trayIcon.Text = "Mihomo Control";
        _trayIcon.Icon = Icon ?? SystemIcons.Application;
        _trayIcon.ContextMenuStrip = trayMenu;
        _trayIcon.Visible = true;
        _trayIcon.DoubleClick += (_, _) => RestoreFromTray();

        Resize += (_, _) =>
        {
            if (WindowState == FormWindowState.Minimized)
                HideToTray();
        };

        FormClosing += (_, e) =>
        {
            if (!_exitRequested && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                HideToTray();
            }
        };

        _statusTimer.Interval = 1000;
        _statusTimer.Tick += async (_, _) => await RefreshStatusTimerAsync();

        Shown += async (_, _) =>
        {
            _installedVersion.Text = await GetInstalledVersionAsync();
            await RefreshLocalStateOnlyAsync();
            _statusTimer.Start();
            _ = RefreshHealthOnlyAsync();
        };

        FormClosed += (_, _) =>
        {
            _statusTimer.Stop();
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
        };
    }

    private void HideToTray()
    {
        Hide();
        ShowInTaskbar = false;
    }

    private void RestoreFromTray()
    {
        ShowInTaskbar = true;
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
        BringToFront();
    }

    private void AddStatusRow(string caption, Label value, int y)
    {
        var key = new Label
        {
            Text = caption + ":",
            ForeColor = SystemColors.GrayText,
            AutoSize = true,
            Location = new Point(27, y + 2)
        };
        value.Text = "—";
        value.AutoSize = false;
        value.Size = new Size(205, 24);
        value.Location = new Point(130, y);
        value.Font = new Font("Segoe UI Semibold", 10F);
        Controls.Add(key);
        Controls.Add(value);
    }

    private static void ConfigureButton(Button button, string text, int x, int y, Control parent, EventHandler handler)
    {
        button.Text = text;
        button.Size = new Size(100, 38);
        button.Location = new Point(x, y);
        button.Click += handler;
        parent.Controls.Add(button);
    }

    private async Task<string> GetInstalledVersionAsync()
    {
        try
        {
            if (!File.Exists(MihomoExe))
                return "not installed";

            var r = await RunProcessCaptureAsync(MihomoExe, "-v", false);
            string combined = (r.stdout + "\n" + r.stderr).Trim();
            var m = Regex.Match(combined, @"\bv\d+\.\d+\.\d+\b", RegexOptions.IgnoreCase);
            return m.Success ? m.Value : "unknown";
        }
        catch
        {
            return "unknown";
        }
    }

    private async Task CheckCoreUpdateAsync()
    {
        if (_busy) return;

        SetBusy(true, "Checking stable Mihomo release...");
        try
        {
            string installed = await GetInstalledVersionAsync();
            _installedVersion.Text = installed;

            using var client = CreateGitHubClient();
            using var response = await client.GetAsync(LatestReleaseApi);
            response.EnsureSuccessStatusCode();

            string json = await response.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            bool prerelease = root.TryGetProperty("prerelease", out var pre) && pre.GetBoolean();
            bool draft = root.TryGetProperty("draft", out var dr) && dr.GetBoolean();
            string tag = root.TryGetProperty("tag_name", out var t) ? (t.GetString() ?? "") : "";

            if (string.IsNullOrWhiteSpace(tag))
                throw new InvalidOperationException("GitHub response did not contain tag_name.");

            if (prerelease || draft)
                throw new InvalidOperationException("GitHub latest endpoint returned a prerelease/draft; update blocked.");

            _latestVersion.Text = tag;

            if (TryParseVersion(installed, out var installedVersion) &&
                TryParseVersion(tag, out var latestVersion))
            {
                if (latestVersion > installedVersion)
                    _updateStatus.Text = "Update available. U1 will NOT download or replace anything.";
                else if (latestVersion == installedVersion)
                    _updateStatus.Text = "Installed core is already the latest stable version.";
                else
                    _updateStatus.Text = "Installed version is newer than latest stable. No action.";
            }
            else
            {
                _updateStatus.Text = "Version found, but comparison was not possible.";
            }
        }
        catch (Exception ex)
        {
            _latestVersion.Text = "check failed";
            _updateStatus.Text = TrimForMessage(ex.Message);
        }
        finally
        {
            SetBusy(false, "Ready");
        }
    }

    private HttpClient CreateGitHubClient()
    {
        string mode = ReadMode();
        var handler = new HttpClientHandler();

        if (mode == "proxy" && Process.GetProcessesByName("mihomo").Length > 0)
        {
            handler.Proxy = new WebProxy("http://127.0.0.1:7890");
            handler.UseProxy = true;
        }
        else
        {
            handler.UseProxy = false;
        }

        var client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(20)
        };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("MihomoControl", "0.4.9.3"));
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }

    private static bool TryParseVersion(string value, out Version version)
    {
        string cleaned = value.Trim();
        if (cleaned.StartsWith("v", StringComparison.OrdinalIgnoreCase))
            cleaned = cleaned[1..];

        return Version.TryParse(cleaned, out version!);
    }


    private sealed record ReleaseAssetInfo(
        string Tag,
        string AssetName,
        string DownloadUrl,
        string Digest);

    private async Task<ReleaseAssetInfo> GetLatestStableWindowsAmd64AssetAsync()
    {
        using var client = CreateGitHubClient();
        using var response = await client.GetAsync(LatestReleaseApi);
        response.EnsureSuccessStatusCode();

        string json = await response.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;

        bool prerelease = root.TryGetProperty("prerelease", out var pre) && pre.GetBoolean();
        bool draft = root.TryGetProperty("draft", out var dr) && dr.GetBoolean();
        string tag = root.TryGetProperty("tag_name", out var t) ? (t.GetString() ?? "") : "";

        if (draft || prerelease)
            throw new InvalidOperationException("Latest release is draft/prerelease. U2 accepts stable only.");

        if (string.IsNullOrWhiteSpace(tag))
            throw new InvalidOperationException("Release tag is missing.");

        if (!root.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array)
            throw new InvalidOperationException("Release does not contain assets.");

        string exactExpectedName = $"mihomo-windows-amd64-{tag}.zip";
        var matches = new List<(string Name, string Url, string Digest)>();

        foreach (var asset in assets.EnumerateArray())
        {
            string name = asset.TryGetProperty("name", out var n) ? (n.GetString() ?? "") : "";

            // Select only the exact standard Windows amd64 asset for this release tag.
            // Examples intentionally rejected:
            // - mihomo-windows-amd64-compatible-...
            // - mihomo-windows-amd64-v1-...
            // - mihomo-windows-amd64-v2-...
            // - mihomo-windows-amd64-v3-...
            // - any future variant with extra tokens
            if (!string.Equals(name, exactExpectedName, StringComparison.OrdinalIgnoreCase))
                continue;

            string url = asset.TryGetProperty("browser_download_url", out var u) ? (u.GetString() ?? "") : "";
            string digest = asset.TryGetProperty("digest", out var d) ? (d.GetString() ?? "") : "";

            matches.Add((name, url, digest));
        }

        if (matches.Count == 0)
        {
            var windowsAmd64Names = assets.EnumerateArray()
                .Select(a => a.TryGetProperty("name", out var n) ? (n.GetString() ?? "") : "")
                .Where(n => n.StartsWith("mihomo-windows-amd64", StringComparison.OrdinalIgnoreCase))
                .ToArray();

            throw new InvalidOperationException(
                $"Exact standard Windows amd64 asset was not found: {exactExpectedName}\n\n" +
                "Available Windows amd64 assets:\n" +
                string.Join("\n", windowsAmd64Names));
        }

        if (matches.Count > 1)
            throw new InvalidOperationException(
                $"Duplicate exact assets found for {exactExpectedName}. Update blocked.");

        var selected = matches[0];

        if (string.IsNullOrWhiteSpace(selected.Url))
            throw new InvalidOperationException("Release asset download URL is missing.");

        if (!selected.Digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Release asset does not expose a SHA256 digest.");

        return new ReleaseAssetInfo(tag, selected.Name, selected.Url, selected.Digest);
    }

    private async Task ValidateLatestCandidateAsync()
    {
        if (_busy)
            return;

        _validatedCandidatePath = null;
        _validatedReleaseTag = null;
        _validatedCandidateSha256 = null;
        SetBusy(true, "Downloading and validating stable candidate...");

        try
        {
            ReleaseAssetInfo release = await GetLatestStableWindowsAmd64AssetAsync();
            _latestVersion.Text = release.Tag;

            string safeTag = Regex.Replace(release.Tag, @"[^A-Za-z0-9._-]", "_");
            string runRoot = Path.Combine(CoreUpdateRoot, safeTag);
            string archivePath = Path.Combine(runRoot, release.AssetName);
            string extractDir = Path.Combine(runRoot, "candidate");

            Directory.CreateDirectory(runRoot);

            if (Directory.Exists(extractDir))
                Directory.Delete(extractDir, true);
            Directory.CreateDirectory(extractDir);

            _updateStatus.Text = $"Downloading {release.AssetName}...";
            await DownloadFileWithFallbackAsync(release.DownloadUrl, archivePath);

            string actualSha = await ComputeSha256Async(archivePath);
            string expectedSha = release.Digest["sha256:".Length..].Trim();

            if (!string.Equals(actualSha, expectedSha, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(
                    "SHA256 mismatch.\n" +
                    $"Expected: {expectedSha}\n" +
                    $"Actual:   {actualSha}");
            }

            _updateStatus.Text = "SHA256 PASS — extracting candidate...";

            ZipFile.ExtractToDirectory(archivePath, extractDir, overwriteFiles: true);

            string[] exeCandidates = Directory.GetFiles(
                extractDir,
                "*.exe",
                SearchOption.AllDirectories);

            if (exeCandidates.Length == 0)
                throw new InvalidOperationException(
                    "No executable file was found in the extracted archive.");

            var validMihomoExecutables = new List<(string Path, string VersionText)>();

            foreach (string exe in exeCandidates)
            {
                try
                {
                    var probe = await RunProcessCaptureAsync(exe, "-v", false);
                    string probeText = (probe.stdout + "\n" + probe.stderr).Trim();

                    if (probe.exitCode == 0 &&
                        probeText.Contains("Mihomo", StringComparison.OrdinalIgnoreCase) &&
                        VersionTextMatchesTag(probeText, release.Tag))
                    {
                        validMihomoExecutables.Add((exe, probeText));
                    }
                }
                catch
                {
                    // Ignore unrelated executables. U2 only accepts executables
                    // that self-identify as Mihomo and match the release tag.
                }
            }

            if (validMihomoExecutables.Count == 0)
            {
                throw new InvalidOperationException(
                    "No extracted executable identified itself as Mihomo " +
                    $"and matched release {release.Tag}.");
            }

            if (validMihomoExecutables.Count > 1)
            {
                throw new InvalidOperationException(
                    "More than one extracted executable identified itself as the expected Mihomo core. " +
                    "Update blocked rather than guessing:\n" +
                    string.Join("\n", validMihomoExecutables.Select(x => x.Path)));
            }

            string candidateExe = validMihomoExecutables[0].Path;
            string versionText = validMihomoExecutables[0].VersionText;

            _updateStatus.Text = "Version PASS — validating Proxy config...";

            var proxyCfg = await RunProcessCaptureAsync(
                candidateExe,
                $"-t -d \"{BaseDir}\" -f \"{ConfigFile}\"",
                false);

            if (proxyCfg.exitCode != 0)
                throw new InvalidOperationException(
                    "Proxy config validation failed with candidate.\n\n" +
                    TrimForMessage(proxyCfg.stderr + "\n" + proxyCfg.stdout));

            _updateStatus.Text = "Proxy config PASS — validating TUN config...";

            var tunCfg = await RunProcessCaptureAsync(
                candidateExe,
                $"-t -d \"{BaseDir}\" -f \"{TunConfigFile}\"",
                false);

            if (tunCfg.exitCode != 0)
                throw new InvalidOperationException(
                    "TUN config validation failed with candidate.\n\n" +
                    TrimForMessage(tunCfg.stderr + "\n" + tunCfg.stdout));

            _validatedCandidatePath = candidateExe;
            _validatedReleaseTag = release.Tag;
            _validatedCandidateSha256 = await ComputeSha256Async(candidateExe);

            _updateStatus.Text =
                $"U2 PASS — SHA256, version, Proxy config and TUN config validated. " +
                $"Candidate is ready for transactional U3 install.";
        }
        catch (Exception ex)
        {
            _updateStatus.Text = "U2 FAIL — current mihomo.exe was NOT changed.";
            MessageBox.Show(
                ex.Message,
                "Mihomo candidate validation",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
        finally
        {
            SetBusy(false, "Ready");
        }
    }

    private async Task InstallValidatedCandidateAsync(bool forceRollbackTest)
    {
        if (_busy)
            return;

        if (string.IsNullOrWhiteSpace(_validatedCandidatePath) ||
            string.IsNullOrWhiteSpace(_validatedReleaseTag) ||
            string.IsNullOrWhiteSpace(_validatedCandidateSha256) ||
            !File.Exists(_validatedCandidatePath))
        {
            MessageBox.Show(
                "Run Download & validate first. U3 only installs a candidate validated in this UI session.",
                "Mihomo core install",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        string confirmText = forceRollbackTest
            ? "TEST-ONLY U3 rollback validation will briefly interrupt the connection, create a real backup, " +
              "replace the Mihomo core with the validated candidate, then intentionally inject a failure AFTER " +
              "the replacement and BEFORE mode restore. The previous core and mode must then be restored automatically.\n\nContinue?"
            : "U3 will briefly interrupt the connection, replace the Mihomo core, restore the current mode, " +
              "and require runtime health 3/3. If any step fails, the previous core will be restored automatically.\n\nContinue?";

        var confirm = MessageBox.Show(
            confirmText,
            forceRollbackTest ? "TEST U3 rollback" : "Install validated Mihomo core",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning,
            MessageBoxDefaultButton.Button2);

        if (confirm != DialogResult.Yes)
            return;

        string originalMode = ReadMode();
        if (originalMode is not ("proxy" or "tun" or "off"))
        {
            MessageBox.Show(
                $"Current mode is invalid: {originalMode}. U3 is blocked.",
                "Mihomo core install",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return;
        }

        string candidatePath = _validatedCandidatePath;
        string releaseTag = _validatedReleaseTag;
        string expectedCandidateSha = _validatedCandidateSha256;
        string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
        string backupDir = Path.Combine(BaseDir, "backups", "core-update", stamp);
        string backupExe = Path.Combine(backupDir, "mihomo.exe");
        string stagingDir = Path.Combine(CoreUpdateRoot, "install-staging", stamp);
        string stagedExe = Path.Combine(stagingDir, "mihomo.exe");
        bool backupCreated = false;
        bool replacementStarted = false;

        SetBusy(
            true,
            forceRollbackTest
                ? "U3 rollback TEST — transactional replacement..."
                : "U3 transactional core install...");

        try
        {
            string currentCandidateSha = await ComputeSha256Async(candidatePath);
            if (!string.Equals(currentCandidateSha, expectedCandidateSha, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Validated candidate changed after U2. Run Download & validate again.");

            _updateStatus.Text = "U3 — revalidating candidate immediately before install...";

            var candidateVersion = await RunProcessCaptureAsync(candidatePath, "-v", false);
            string candidateVersionText = (candidateVersion.stdout + "\n" + candidateVersion.stderr).Trim();
            if (candidateVersion.exitCode != 0 ||
                !candidateVersionText.Contains("Mihomo", StringComparison.OrdinalIgnoreCase) ||
                !VersionTextMatchesTag(candidateVersionText, releaseTag))
            {
                throw new InvalidOperationException("Candidate identity/version revalidation failed before install.");
            }

            var proxyCfg = await RunProcessCaptureAsync(
                candidatePath,
                $"-t -d \"{BaseDir}\" -f \"{ConfigFile}\"",
                false);
            if (proxyCfg.exitCode != 0)
                throw new InvalidOperationException("Proxy config no longer validates with candidate.");

            var tunCfg = await RunProcessCaptureAsync(
                candidatePath,
                $"-t -d \"{BaseDir}\" -f \"{TunConfigFile}\"",
                false);
            if (tunCfg.exitCode != 0)
                throw new InvalidOperationException("TUN config no longer validates with candidate.");

            Directory.CreateDirectory(backupDir);
            Directory.CreateDirectory(stagingDir);

            File.Copy(MihomoExe, backupExe, true);
            backupCreated = true;

            File.WriteAllText(
                Path.Combine(backupDir, "transaction.txt"),
                $"timestamp={DateTime.Now:O}\n" +
                $"originalMode={originalMode}\n" +
                $"candidateRelease={releaseTag}\n" +
                $"candidateSha256={expectedCandidateSha}\n",
                Encoding.UTF8);

            File.Copy(candidatePath, stagedExe, true);
            string stagedSha = await ComputeSha256Async(stagedExe);
            if (!string.Equals(stagedSha, expectedCandidateSha, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Staging copy SHA256 mismatch.");

            _updateStatus.Text = $"U3 — backup created; stopping {originalMode.ToUpperInvariant()} mode...";

            // Put the watchdog into its idle state before stopping Proxy mode.
            File.WriteAllText(ModeFile, "off", Encoding.UTF8);
            await StopCoreForTransactionAsync(originalMode);

            if (!await WaitForMihomoExitAsync(TimeSpan.FromSeconds(12)))
                throw new InvalidOperationException("Mihomo process did not stop. Core replacement blocked.");

            replacementStarted = true;
            _updateStatus.Text = "U3 — installing validated core...";

            File.Move(stagedExe, MihomoExe, true);

            var installedProbe = await RunProcessCaptureAsync(MihomoExe, "-v", false);
            string installedText = (installedProbe.stdout + "\n" + installedProbe.stderr).Trim();
            if (installedProbe.exitCode != 0 || !VersionTextMatchesTag(installedText, releaseTag))
                throw new InvalidOperationException("Installed core version probe failed after replacement.");

            if (forceRollbackTest)
            {
                _updateStatus.Text = "U3 rollback TEST — replacement verified; injecting controlled failure...";
                throw new InvalidOperationException(
                    "CONTROLLED TEST FAILURE after verified core replacement. Automatic rollback is expected.");
            }

            _updateStatus.Text = $"U3 — restoring {originalMode.ToUpperInvariant()} mode...";
            await RestoreModeForTransactionAsync(originalMode);

            bool runtimeOk = await WaitForRuntimeHealthyAsync(originalMode, TimeSpan.FromSeconds(45));
            if (!runtimeOk)
                throw new InvalidOperationException(
                    originalMode == "off"
                        ? "OFF mode did not restore cleanly."
                        : "Runtime health did not reach 3/3 after installing the candidate.");

            _installedVersion.Text = await GetInstalledVersionAsync();
            _updateStatus.Text =
                $"U3 PASS — {releaseTag} installed transactionally; {originalMode.ToUpperInvariant()} restored; " +
                (originalMode == "off" ? "OFF state verified." : "runtime health 3/3.");

            MessageBox.Show(
                "U3 PASS. The validated core was installed and the previous mode was restored successfully.",
                "Mihomo core install",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception installError)
        {
            string rollbackResult;

            if (backupCreated)
            {
                try
                {
                    _updateStatus.Text = "U3 FAIL — rolling back previous core...";

                    File.WriteAllText(ModeFile, "off", Encoding.UTF8);
                    await StopCoreForTransactionAsync(originalMode);

                    if (!await WaitForMihomoExitAsync(TimeSpan.FromSeconds(12)))
                        throw new InvalidOperationException("Rollback could not stop the active Mihomo process.");

                    File.Copy(backupExe, MihomoExe, true);

                    var rollbackProbe = await RunProcessCaptureAsync(MihomoExe, "-v", false);
                    if (rollbackProbe.exitCode != 0)
                        throw new InvalidOperationException("Restored previous core failed version probe.");

                    await RestoreModeForTransactionAsync(originalMode);
                    bool rollbackHealthy = await WaitForRuntimeHealthyAsync(originalMode, TimeSpan.FromSeconds(45));
                    if (!rollbackHealthy)
                        throw new InvalidOperationException("Previous mode/core restored, but runtime verification failed.");

                    rollbackResult = forceRollbackTest
                        ? "ROLLBACK TEST PASS — previous core and mode restored after controlled failure."
                        : "ROLLBACK PASS — previous core and mode restored.";

                    _updateStatus.Text = forceRollbackTest
                        ? "U3 ROLLBACK TEST PASS — previous core and mode restored."
                        : "U3 FAIL — rollback PASS. Previous core and mode restored.";
                }
                catch (Exception rollbackError)
                {
                    rollbackResult = "ROLLBACK FAILED: " + TrimForMessage(rollbackError.Message);
                    _updateStatus.Text = "U3 FAIL — ROLLBACK FAILED. Manual recovery required.";
                }
            }
            else
            {
                rollbackResult = replacementStarted
                    ? "No backup was available after replacement began. Manual recovery required."
                    : "Replacement never began; working core was not changed.";
                _updateStatus.Text = replacementStarted
                    ? "U3 FAIL — manual recovery required."
                    : "U3 FAIL — replacement never began; current core unchanged.";
            }

            MessageBox.Show(
                TrimForMessage(installError.Message) + "\n\n" + rollbackResult,
                forceRollbackTest ? "U3 rollback test" : "Mihomo core install",
                MessageBoxButtons.OK,
                forceRollbackTest && rollbackResult.StartsWith("ROLLBACK TEST PASS", StringComparison.Ordinal)
                    ? MessageBoxIcon.Information
                    : MessageBoxIcon.Warning);
        }
        finally
        {
            try { await RefreshStateAsync(); } catch { }
            SetBusy(false, "Ready");
        }
    }

    private static async Task StopCoreForTransactionAsync(string originalMode)
    {
        if (originalMode == "tun")
        {
            var stopTun = await RunProcessCaptureAsync(
                "pwsh.exe",
                $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{Path.Combine(ScriptsDir, "Stop-MihomoTun.ps1")}\"",
                true);

            if (stopTun.exitCode != 0)
                throw new InvalidOperationException($"Stop-MihomoTun.ps1 failed with exit code {stopTun.exitCode}.");
        }
        else
        {
            // Proxy uses this script normally. In OFF mode it also cleans up a stray core if one exists.
            var stopProxy = await RunProcessCaptureAsync(
                "pwsh.exe",
                $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{Path.Combine(ScriptsDir, "Stop-Mihomo.ps1")}\"",
                false);

            if (stopProxy.exitCode != 0 && Process.GetProcessesByName("mihomo").Length > 0)
                throw new InvalidOperationException($"Stop-Mihomo.ps1 failed with exit code {stopProxy.exitCode}.");
        }
    }

    private static async Task RestoreModeForTransactionAsync(string mode)
    {
        if (mode == "proxy")
        {
            // Proxy restore must follow the same detached architecture as the UI button.
            // Do not capture/await Start-Mihomo.ps1 because its background children can
            // keep inherited redirected handles alive after the launcher itself exits.
            var psi = new ProcessStartInfo
            {
                FileName = "pwsh.exe",
                Arguments =
                    $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{Path.Combine(ScriptsDir, "Start-Mihomo.ps1")}\"",
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            Process.Start(psi);

            // WaitForRuntimeHealthyAsync() is the authoritative gate for Proxy restore.
            await Task.Delay(300);
        }
        else if (mode == "tun")
        {
            var startTun = await RunProcessCaptureAsync(
                "pwsh.exe",
                $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{Path.Combine(ScriptsDir, "Start-MihomoTun.ps1")}\"",
                true);

            if (startTun.exitCode != 0)
                throw new InvalidOperationException($"Start-MihomoTun.ps1 failed with exit code {startTun.exitCode}.");
        }
        else
        {
            File.WriteAllText(ModeFile, "off", Encoding.UTF8);
        }
    }

    private static async Task<bool> WaitForMihomoExitAsync(TimeSpan timeout)
    {
        DateTime deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (Process.GetProcessesByName("mihomo").Length == 0)
                return true;
            await Task.Delay(300);
        }
        return Process.GetProcessesByName("mihomo").Length == 0;
    }

    private static async Task<bool> WaitForRuntimeHealthyAsync(string expectedMode, TimeSpan timeout)
    {
        DateTime deadline = DateTime.UtcNow + timeout;

        while (DateTime.UtcNow < deadline)
        {
            string mode = ReadMode();
            bool running = Process.GetProcessesByName("mihomo").Length > 0;

            if (expectedMode == "off")
            {
                if (mode == "off" && !running)
                    return true;
            }
            else if (mode == expectedMode && running)
            {
                string health = await CheckHealthAsync();
                if (health == "3/3")
                    return true;
            }

            await Task.Delay(1000);
        }

        return false;
    }

    private static bool VersionTextMatchesTag(string versionText, string tag)
    {
        string expected = tag.StartsWith("v", StringComparison.OrdinalIgnoreCase)
            ? tag
            : "v" + tag;

        return versionText.Contains(expected, StringComparison.OrdinalIgnoreCase);
    }

    private static async Task<string> ComputeSha256Async(string path)
    {
        await using var stream = File.OpenRead(path);
        byte[] hash = await SHA256.HashDataAsync(stream);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static async Task DownloadFileWithFallbackAsync(string url, string destination)
    {
        if (File.Exists(destination))
            File.Delete(destination);

        var direct = await RunCurlDownloadAsync(
            url,
            destination,
            proxyUrl: null);

        if (direct.exitCode == 0 && File.Exists(destination) && new FileInfo(destination).Length > 0)
            return;

        string directError = TrimForMessage(
            (direct.stderr + "\n" + direct.stdout).Trim());

        if (File.Exists(destination))
            File.Delete(destination);

        if (Process.GetProcessesByName("mihomo").Length == 0)
        {
            throw new InvalidOperationException(
                "DIRECT core download failed and Mihomo is not running for proxy fallback.\n\n" +
                "DIRECT: " + directError);
        }

        var proxied = await RunCurlDownloadAsync(
            url,
            destination,
            proxyUrl: "http://127.0.0.1:7890");

        if (proxied.exitCode == 0 && File.Exists(destination) && new FileInfo(destination).Length > 0)
            return;

        string proxyError = TrimForMessage(
            (proxied.stderr + "\n" + proxied.stdout).Trim());

        if (File.Exists(destination))
            File.Delete(destination);

        throw new InvalidOperationException(
            "Core download failed both DIRECT and via Mihomo proxy.\n\n" +
            "DIRECT: " + directError + "\n\n" +
            "MIHOMO: " + proxyError);
    }

    private static async Task<(int exitCode, string stdout, string stderr)> RunCurlDownloadAsync(
        string url,
        string destination,
        string? proxyUrl)
    {
        string curlExe = "curl.exe";

        var args = new List<string>
        {
            "--fail",
            "--location",
            "--ssl-no-revoke",
            "--retry", "3",
            "--retry-all-errors",
            "--retry-delay", "2",
            "--connect-timeout", "15",
            "--max-time", "300",
            "--output", Quote(destination)
        };

        if (string.IsNullOrWhiteSpace(proxyUrl))
        {
            args.Add("--noproxy");
            args.Add("\"*\"");
        }
        else
        {
            args.Add("--proxy");
            args.Add(Quote(proxyUrl));
        }

        args.Add(Quote(url));

        string joined = string.Join(" ", args);

        var psi = new ProcessStartInfo
        {
            FileName = curlExe,
            Arguments = joined,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        using var p = Process.Start(psi)
            ?? throw new InvalidOperationException("Could not start curl.exe.");

        Task<string> stdoutTask = p.StandardOutput.ReadToEndAsync();
        Task<string> stderrTask = p.StandardError.ReadToEndAsync();

        await p.WaitForExitAsync();

        return (p.ExitCode, await stdoutTask, await stderrTask);
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private void PasteInput()
    {
        if (!Clipboard.ContainsText())
        {
            MessageBox.Show("Clipboard does not contain text.");
            return;
        }

        _pendingText = Clipboard.GetText().Trim();
        string type = DetectInputType(_pendingText);
        _subscriptionInfo.Text = $"Detected: {type}";
        _apply.Enabled = false;
        _test.Enabled = true;
    }

    private static string DetectInputType(string text)
    {
        string t = text.Trim();

        if (Uri.TryCreate(t, UriKind.Absolute, out var uri) &&
            (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps))
            return "Subscription URL";

        if (t.StartsWith("{") || t.StartsWith("["))
            return "JSON";

        if (t.Contains("proxies:", StringComparison.OrdinalIgnoreCase))
            return "YAML proxy config";

        if (Regex.IsMatch(t, @"(?mi)^(vless|vmess|ss|trojan|hysteria2?|tuic|wireguard)://"))
            return "URI list";

        string compact = Regex.Replace(t, @"\s+", "");
        if (compact.Length >= 16 && compact.Length % 4 == 0)
        {
            try
            {
                Convert.FromBase64String(compact);
                return "Base64";
            }
            catch { }
        }

        return "Unsupported / unknown";
    }

    private async Task<(string type, string content)> NormalizeInputAsync(string raw, int depth = 0)
    {
        if (depth > 4)
            throw new InvalidOperationException("Too many nested encodings.");

        string type = DetectInputType(raw);
        string content = raw.Trim();

        if (type == "Subscription URL")
        {
            string downloaded = await DownloadDirectAsync(content);
            return await NormalizeInputAsync(downloaded, depth + 1);
        }

        if (type == "Base64")
        {
            string compact = Regex.Replace(content, @"\s+", "");
            byte[] bytes = Convert.FromBase64String(compact);
            string decoded = Encoding.UTF8.GetString(bytes).Trim();

            if (string.IsNullOrWhiteSpace(decoded))
                throw new InvalidOperationException("Base64 decoded to empty content.");

            return await NormalizeInputAsync(decoded, depth + 1);
        }

        if (type is "URI list" or "YAML proxy config" or "JSON")
            return (type, content);

        throw new InvalidOperationException("Unsupported subscription/config format.");
    }

    private async Task TestPendingAsync()
    {
        if (string.IsNullOrWhiteSpace(_pendingText))
            return;

        SetBusy(true, "Testing import...");

        string runDir = Path.Combine(ValidationRoot, DateTime.Now.ToString("yyyyMMdd-HHmmssfff"));

        try
        {
            var normalized = await NormalizeInputAsync(_pendingText);
            int nodes = EstimateNodeCount(normalized.content);

            Directory.CreateDirectory(runDir);
            string tempProvider = Path.Combine(runDir, "provider.txt");
            string tempConfig = Path.Combine(runDir, "config.yaml");

            File.WriteAllText(tempProvider, normalized.content.Trim() + Environment.NewLine, Encoding.UTF8);
            File.WriteAllText(tempConfig, BuildValidationConfig(tempProvider), Encoding.UTF8);

            var result = await RunProcessCaptureAsync(
                MihomoExe,
                $"-t -d \"{BaseDir}\" -f \"{tempConfig}\"",
                false);

            if (result.exitCode != 0)
            {
                string details = string.IsNullOrWhiteSpace(result.stderr) ? result.stdout : result.stderr;
                throw new InvalidOperationException("Mihomo validation failed.\n\n" + TrimForMessage(details));
            }

            _subscriptionInfo.Text =
                $"Test PASS — normalized as {normalized.type}, approx. {nodes} node(s)";
            _apply.Enabled = DetectInputType(_pendingText) == "Subscription URL";
        }
        catch (Exception ex)
        {
            _subscriptionInfo.Text = "Test FAIL";
            _apply.Enabled = false;
            MessageBox.Show(ex.Message, "Subscription test", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            try
            {
                if (Directory.Exists(runDir))
                    Directory.Delete(runDir, true);
            }
            catch { }

            SetBusy(false, "Ready");
        }
    }

    private static async Task<string> DownloadDirectAsync(string url)
    {
        Exception? directError = null;

        try
        {
            using var directHandler = new HttpClientHandler
            {
                UseProxy = false,
                AllowAutoRedirect = true
            };

            using var directClient = new HttpClient(directHandler)
            {
                Timeout = TimeSpan.FromSeconds(15)
            };

            using var directResponse = await directClient.GetAsync(url);
            directResponse.EnsureSuccessStatusCode();
            return await directResponse.Content.ReadAsStringAsync();
        }
        catch (Exception ex)
        {
            directError = ex;
        }

        bool mihomoRunning = Process.GetProcessesByName("mihomo").Length > 0;

        if (!mihomoRunning)
        {
            throw new InvalidOperationException(
                "DIRECT download failed and Mihomo is not running, so proxy fallback is unavailable.\n\n" +
                "DIRECT: " + directError?.Message);
        }

        try
        {
            using var proxyHandler = new HttpClientHandler
            {
                Proxy = new WebProxy("http://127.0.0.1:7890"),
                UseProxy = true,
                AllowAutoRedirect = true
            };

            using var proxyClient = new HttpClient(proxyHandler)
            {
                Timeout = TimeSpan.FromSeconds(20)
            };

            using var proxyResponse = await proxyClient.GetAsync(url);
            proxyResponse.EnsureSuccessStatusCode();
            return await proxyResponse.Content.ReadAsStringAsync();
        }
        catch (Exception proxyError)
        {
            throw new InvalidOperationException(
                "Subscription download failed both DIRECT and via Mihomo proxy.\n\n" +
                "DIRECT: " + directError?.Message + "\n\n" +
                "MIHOMO: " + proxyError.Message);
        }
    }

    private static int EstimateNodeCount(string content)
    {
        int uriCount = Regex.Matches(
            content,
            @"(?mi)^(vless|vmess|ss|trojan|hysteria2?|tuic|wireguard)://").Count;

        if (uriCount > 0) return uriCount;

        if (content.Contains("proxies:", StringComparison.OrdinalIgnoreCase))
        {
            int yamlCount = Regex.Matches(content, @"(?m)^\s*-\s*name\s*:").Count;
            return Math.Max(yamlCount, 1);
        }

        return 1;
    }

    private static string BuildValidationConfig(string providerPath)
    {
        string escaped = providerPath.Replace(@"\", "/");

        return $"""
mixed-port: 17890
allow-lan: false
mode: rule
log-level: info
external-controller: 127.0.0.1:19090

proxy-providers:
  import:
    type: file
    path: "{escaped}"

proxy-groups:
  - name: AUTO
    type: select
    use:
      - import

rules:
  - MATCH,AUTO
""";
    }

    private async Task ApplyPendingAsync()
    {
        if (string.IsNullOrWhiteSpace(_pendingText) || !_apply.Enabled)
            return;

        SetBusy(true, "Applying subscription...");

        try
        {
            if (DetectInputType(_pendingText) != "Subscription URL")
                throw new InvalidOperationException("Apply currently persists URL subscriptions only.");

            string url = _pendingText.Trim();
            var normalized = await NormalizeInputAsync(url);

            if (string.IsNullOrWhiteSpace(normalized.content))
                throw new InvalidOperationException("Subscription content is empty.");

            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            string backupDir = Path.Combine(BaseDir, "backups", "subscription-" + stamp);
            Directory.CreateDirectory(backupDir);

            BackupIfExists(SubscriptionFile, backupDir);
            BackupIfExists(ConfigFile, backupDir);
            BackupIfExists(TunConfigFile, backupDir);
            BackupIfExists(TemplateFile, backupDir);

            File.WriteAllText(SubscriptionFile, url + Environment.NewLine, Encoding.UTF8);

            ReplaceSubscriptionUrlInConfig(ConfigFile, url);
            ReplaceSubscriptionUrlInConfig(TunConfigFile, url);
            ReplaceSubscriptionUrlInConfig(TemplateFile, url);

            var cfg = await RunProcessCaptureAsync(MihomoExe, $"-t -d \"{BaseDir}\" -f \"{ConfigFile}\"", false);
            var tun = await RunProcessCaptureAsync(MihomoExe, $"-t -d \"{BaseDir}\" -f \"{TunConfigFile}\"", false);

            if (cfg.exitCode != 0 || tun.exitCode != 0)
            {
                RestoreBackup(backupDir);

                string details =
                    (cfg.exitCode != 0 ? cfg.stderr + "\n" + cfg.stdout : "") +
                    (tun.exitCode != 0 ? tun.stderr + "\n" + tun.stdout : "");

                throw new InvalidOperationException(
                    "Validation failed. Previous configuration restored.\n\n" + TrimForMessage(details));
            }

            string modeBeforeApply = ReadMode();

            try
            {
                _subscriptionInfo.Text = $"Config updated — reloading {modeBeforeApply.ToUpperInvariant()} runtime...";
                await ReloadRuntimeAfterSubscriptionApplyAsync(modeBeforeApply);

                if (modeBeforeApply != "off")
                {
                    await UpdateProviderNowAsync();
                }

                _subscriptionInfo.Text =
                    modeBeforeApply == "off"
                        ? $"Apply PASS — source: {new Uri(url).Host}; will load on next start"
                        : $"Apply PASS — source: {new Uri(url).Host}; runtime reloaded";
            }
            catch
            {
                // Runtime did not accept the new subscription/config.
                // Restore the complete file backup and return to the previous runtime mode.
                RestoreBackup(backupDir);

                try
                {
                    await ReloadRuntimeAfterSubscriptionApplyAsync(modeBeforeApply);
                }
                catch
                {
                    // Preserve the original runtime-apply exception below.
                }

                throw;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Apply subscription", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            SetBusy(false, "Ready");
        }
    }

    private static void BackupIfExists(string path, string backupDir)
    {
        if (File.Exists(path))
            File.Copy(path, Path.Combine(backupDir, Path.GetFileName(path)), true);
    }

    private static void RestoreBackup(string backupDir)
    {
        foreach (string file in Directory.GetFiles(backupDir))
            File.Copy(file, Path.Combine(BaseDir, Path.GetFileName(file)), true);
    }

    private static void ReplaceSubscriptionUrlInConfig(string path, string url)
    {
        if (!File.Exists(path)) return;

        string text = File.ReadAllText(path);

        var regex = new Regex(
            @"(?ms)(proxy-providers:\s*\r?\n\s*subscription:\s*.*?\r?\n\s*url:\s*)(""[^""]*""|'[^']*'|[^\r\n]+)");

        if (!regex.IsMatch(text)) return;

        string safeUrl = url.Replace("\"", "\\\"");
        text = regex.Replace(text, $"$1\"{safeUrl}\"", 1);
        File.WriteAllText(path, text, Encoding.UTF8);
    }

    private async Task ReloadRuntimeAfterSubscriptionApplyAsync(string mode)
    {
        if (mode == "off")
            return;

        if (mode == "proxy")
        {
            string script = Path.Combine(ScriptsDir, "Start-Mihomo.ps1");

            // Proxy architecture is intentionally detached.
            var psi = new ProcessStartInfo
            {
                FileName = "pwsh.exe",
                Arguments =
                    $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\" -Restart",
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            Process.Start(psi);

            DateTime deadline = DateTime.Now.AddSeconds(35);
            while (DateTime.Now < deadline)
            {
                await Task.Delay(500);

                bool running = Process.GetProcessesByName("mihomo").Length == 1;
                var proxy = ReadSystemProxy();

                if (ReadMode() == "proxy" &&
                    running &&
                    proxy.enabled &&
                    string.Equals(proxy.server, "127.0.0.1:7890", StringComparison.OrdinalIgnoreCase))
                {
                    // Controller should be alive before provider refresh is requested.
                    try
                    {
                        using var handler = new HttpClientHandler { UseProxy = false };
                        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(2) };
                        using var response = await client.GetAsync("http://127.0.0.1:9090/version");
                        if (response.IsSuccessStatusCode)
                            return;
                    }
                    catch
                    {
                    }
                }
            }

            throw new InvalidOperationException(
                "New subscription was written and validated, but Proxy runtime did not restart cleanly. " +
                "Previous subscription/config backup will be restored.");
        }

        if (mode == "tun")
        {
            string script = Path.Combine(ScriptsDir, "Start-MihomoTun.ps1");

            var result = await RunProcessCaptureAsync(
                "pwsh.exe",
                $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\"",
                true);

            if (result.exitCode != 0)
            {
                throw new InvalidOperationException(
                    $"New subscription was written and validated, but TUN runtime restart failed with exit code {result.exitCode}. " +
                    "Previous subscription/config backup will be restored.");
            }

            DateTime deadline = DateTime.Now.AddSeconds(25);
            while (DateTime.Now < deadline)
            {
                await Task.Delay(500);

                if (ReadMode() == "tun" &&
                    Process.GetProcessesByName("mihomo").Length == 1 &&
                    !ReadSystemProxy().enabled)
                {
                    return;
                }
            }

            throw new InvalidOperationException(
                "TUN runtime did not become ready after applying the new subscription. " +
                "Previous subscription/config backup will be restored.");
        }

        throw new InvalidOperationException($"Unsupported runtime mode during subscription apply: {mode}");
    }

    private async Task UpdateProviderNowAsync()
    {
        try
        {
            using var handler = new HttpClientHandler { UseProxy = false };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };

            using var req = new HttpRequestMessage(
                HttpMethod.Put,
                "http://127.0.0.1:9090/providers/proxies/subscription");

            using var resp = await client.SendAsync(req);
            if (!resp.IsSuccessStatusCode)
                throw new InvalidOperationException($"Provider update returned {(int)resp.StatusCode}.");

            _subscriptionInfo.Text = "Provider update requested successfully";
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Update provider", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async Task SwitchModeAsync(string targetMode)
    {
        if (_busy) return;
        string current = ReadMode();
        if (current == targetMode) return;

        SetBusy(true, $"Switching to {targetMode.ToUpperInvariant()}...");

        bool detachedProxyTransition = false;

        try
        {
            if (targetMode == "proxy")
            {
                // Proxy remains fully detached from the UI:
                // no redirected stdout/stderr and no await on Start-Mihomo.ps1.
                StartDetachedProxySwitch();
                detachedProxyTransition = true;
            }
            else if (targetMode == "tun")
            {
                await RunProcessCaptureAsync("pwsh.exe",
                    $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{Path.Combine(ScriptsDir, "Start-MihomoTun.ps1")}\"",
                    true);
            }
            else
            {
                string script = current == "tun" ? "Stop-MihomoTun.ps1" : "Stop-Mihomo.ps1";
                await RunProcessCaptureAsync("pwsh.exe",
                    $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{Path.Combine(ScriptsDir, script)}\"",
                    current == "tun");
            }
        }
        finally
        {
            if (detachedProxyTransition)
            {
                // The backend is intentionally asynchronous, so a single refresh at
                // +300 ms can still show the old OFF/TUN state. Release the UI now,
                // then follow the transition locally for a few seconds.
                SetBusy(false, "Starting Proxy...");
                _ = FollowDetachedProxyStateAsync();
            }
            else
            {
                await Task.Delay(300);
                await RefreshLocalStateOnlyAsync();
                SetBusy(false, "Ready");
                _ = RefreshHealthOnlyAsync();
            }
        }
    }

    private async Task FollowDetachedProxyStateAsync()
    {
        try
        {
            for (int i = 0; i < 20; i++)
            {
                await Task.Delay(250);
                await RefreshLocalStateOnlyAsync();

                string mode = ReadMode();
                bool running = Process.GetProcessesByName("mihomo").Length > 0;
                var proxy = ReadSystemProxy();

                if (mode == "proxy" && running && proxy.enabled)
                {
                    _operationValue.Text = "Ready";
                    _ = RefreshHealthOnlyAsync();
                    return;
                }
            }

            // Do not freeze or disable controls if activation is slow/fails.
            // Leave the latest local state visible and let watchdog / manual Refresh
            // provide subsequent updates.
            _operationValue.Text = "Proxy activation pending";
            _ = RefreshHealthOnlyAsync();
        }
        catch
        {
            _operationValue.Text = "Ready";
        }
    }

    private void StartDetachedProxySwitch()
    {
        string script = Path.Combine(ScriptsDir, "Start-Mihomo.ps1");

        var psi = new ProcessStartInfo
        {
            FileName = "pwsh.exe",
            Arguments =
                $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\"",
            UseShellExecute = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };

        Process.Start(psi);
    }

    private async Task RunScriptAsync(string script, bool elevated, params string[] args)
    {
        SetBusy(true, "Working...");
        try
        {
            string full = Path.Combine(ScriptsDir, script);
            string tail = args.Length > 0 ? " " + string.Join(" ", args) : "";
            await RunProcessCaptureAsync("pwsh.exe",
                $"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{full}\"{tail}",
                elevated);
        }
        finally
        {
            await Task.Delay(400);
            await RefreshStateAsync();
            SetBusy(false, "Ready");
        }
    }

    private static async Task<(int exitCode, string stdout, string stderr)> RunProcessCaptureAsync(
        string file, string args, bool elevated)
    {
        if (elevated)
        {
            var elevatedPsi = new ProcessStartInfo
            {
                FileName = file,
                Arguments = args,
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden
            };

            using var elevatedProcess = Process.Start(elevatedPsi)
                ?? throw new InvalidOperationException("Could not start process.");

            await elevatedProcess.WaitForExitAsync();
            return (elevatedProcess.ExitCode, "", "");
        }

        var psi = new ProcessStartInfo
        {
            FileName = file,
            Arguments = args,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        using var p = Process.Start(psi)
            ?? throw new InvalidOperationException("Could not start process.");

        Task<string> stdoutTask = p.StandardOutput.ReadToEndAsync();
        Task<string> stderrTask = p.StandardError.ReadToEndAsync();

        await p.WaitForExitAsync();
        return (p.ExitCode, await stdoutTask, await stderrTask);
    }

    private async Task ShowAboutAsync()
    {
        string coreVersion;
        try
        {
            coreVersion = await GetInstalledVersionAsync();
        }
        catch
        {
            coreVersion = "unknown";
        }

        MessageBox.Show(
            "Mihomo Control\n" +
            "Version 0.4.9.3\n\n" +
            $"Mihomo core: {coreVersion}\n\n" +
            "Windows controller for Mihomo Proxy / TUN modes.\n" +
            "Subscription credentials and provider contents are not included in diagnostics.",
            "About Mihomo Control",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }

    private async Task CopyDiagnosticsAsync()
    {
        if (_busy)
            return;

        SetBusy(true, "Collecting diagnostics...");

        try
        {
            string report = await BuildSafeDiagnosticsAsync();
            Clipboard.SetText(report);

            _operationValue.Text = "Diagnostics copied to clipboard";
            MessageBox.Show(
                "Safe diagnostics copied to clipboard.\n\n" +
                "Subscription URLs, UUIDs, credentials, provider contents and config contents are not included.",
                "Diagnostics",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                ex.Message,
                "Diagnostics",
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
        }
        finally
        {
            SetBusy(false, "Ready");
        }
    }

    private async Task<string> BuildSafeDiagnosticsAsync()
    {
        var sb = new StringBuilder();

        sb.AppendLine("Mihomo Control Diagnostics");
        sb.AppendLine("==========================");
        sb.AppendLine($"Time: {DateTime.Now:O}");
        sb.AppendLine($"UI version: 0.4.9.3");
        sb.AppendLine($"Mihomo version: {await GetInstalledVersionAsync()}");
        sb.AppendLine($"Mode: {ReadMode()}");

        var mihomoProcesses = Process.GetProcessesByName("mihomo");
        sb.AppendLine($"Mihomo process count: {mihomoProcesses.Length}");
        foreach (var p in mihomoProcesses)
        {
            sb.AppendLine($"  PID: {p.Id}");
        }

        var proxy = ReadSystemProxy();
        sb.AppendLine($"System proxy enabled: {proxy.enabled}");
        sb.AppendLine($"System proxy server: {(proxy.enabled ? proxy.server : "(off)")}");

        bool port7890 = await TestLocalPortAsync(7890);
        bool port9090 = await TestLocalPortAsync(9090);
        sb.AppendLine($"Port 7890: {(port7890 ? "OPEN" : "CLOSED")}");
        sb.AppendLine($"Port 9090: {(port9090 ? "OPEN" : "CLOSED")}");

        sb.AppendLine($"Active node: {await ReadActiveNodeAsync()}");
        sb.AppendLine($"Watchdog state: {ReadWatchdogState()}");

        string health = mihomoProcesses.Length > 0
            ? await CheckHealthAsync()
            : "—";
        sb.AppendLine($"Health: {health}");

        int watchdogCount = 0;
        try
        {
            using var searcher = new System.Management.ManagementObjectSearcher(
                "SELECT ProcessId, Name, CommandLine FROM Win32_Process WHERE Name='pwsh.exe' OR Name='powershell.exe'");
            foreach (System.Management.ManagementObject obj in searcher.Get())
            {
                string cmd = Convert.ToString(obj["CommandLine"]) ?? "";
                if (cmd.Contains("Watch-Mihomo.ps1", StringComparison.OrdinalIgnoreCase))
                    watchdogCount++;
            }
        }
        catch
        {
            watchdogCount = -1;
        }

        sb.AppendLine($"Watchdog process count: {(watchdogCount >= 0 ? watchdogCount.ToString() : "unknown")}");
        sb.AppendLine();
        sb.AppendLine("Privacy:");
        sb.AppendLine("- subscription URL: NOT INCLUDED");
        sb.AppendLine("- UUID / credentials / keys: NOT INCLUDED");
        sb.AppendLine("- provider contents: NOT INCLUDED");
        sb.AppendLine("- config contents: NOT INCLUDED");
        sb.AppendLine("- logs: NOT INCLUDED");

        return sb.ToString();
    }

    private static async Task<bool> TestLocalPortAsync(int port)
    {
        try
        {
            using var client = new System.Net.Sockets.TcpClient();
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            await client.ConnectAsync("127.0.0.1", port, cts.Token);
            return client.Connected;
        }
        catch
        {
            return false;
        }
    }

    private async Task RefreshStatusTimerAsync()
    {
        if (_statusRefreshRunning || _busy || IsDisposed || Disposing)
            return;

        _statusRefreshRunning = true;
        try
        {
            await RefreshLocalStateOnlyAsync();
        }
        catch
        {
            // Periodic local-state synchronization must never break the UI.
        }
        finally
        {
            _statusRefreshRunning = false;
        }
    }

    private async Task RefreshLocalStateOnlyAsync()
    {
        string mode = ReadMode();
        bool running = Process.GetProcessesByName("mihomo").Length > 0;
        var proxy = ReadSystemProxy();

        _modeValue.Text = mode.ToUpperInvariant();
        _processValue.Text = running ? "RUNNING" : "STOPPED";
        _proxyValue.Text = proxy.enabled ? $"ON ({proxy.server})" : "OFF";
        _nodeValue.Text = await ReadActiveNodeAsync();
        _watchdogValue.Text = ReadWatchdogState();

        ApplyButtonState(mode, running);
    }

    private async Task RefreshStateAsync(bool includeHealth = true)
    {
        string mode = ReadMode();
        bool running = Process.GetProcessesByName("mihomo").Length > 0;
        var proxy = ReadSystemProxy();

        _modeValue.Text = mode.ToUpperInvariant();
        _processValue.Text = running ? "RUNNING" : "STOPPED";
        _proxyValue.Text = proxy.enabled ? $"ON ({proxy.server})" : "OFF";
        _nodeValue.Text = await ReadActiveNodeAsync();
        _watchdogValue.Text = ReadWatchdogState();

        if (!running)
            _healthValue.Text = "—";
        else if (includeHealth)
            _healthValue.Text = await CheckHealthAsync();
        else
            _healthValue.Text = "checking...";

        ApplyButtonState(mode, running);
    }

    private async Task RefreshHealthOnlyAsync()
    {
        try
        {
            bool running = Process.GetProcessesByName("mihomo").Length > 0;
            if (!running)
            {
                _healthValue.Text = "—";
                return;
            }

            _healthValue.Text = await CheckHealthAsync();
        }
        catch
        {
            _healthValue.Text = "—";
        }
    }

    private static string ReadMode()
    {
        try
        {
            if (!File.Exists(ModeFile)) return "proxy";
            string mode = File.ReadAllText(ModeFile).Trim().ToLowerInvariant();
            return mode is "proxy" or "tun" or "off" ? mode : "unknown";
        }
        catch { return "unknown"; }
    }

    private static (bool enabled, string server) ReadSystemProxy()
    {
        try
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
            bool enabled = Convert.ToInt32(key?.GetValue("ProxyEnable", 0) ?? 0) != 0;
            string server = Convert.ToString(key?.GetValue("ProxyServer", "")) ?? "";
            return (enabled, server);
        }
        catch { return (false, ""); }
    }

    private static async Task<string> ReadActiveNodeAsync()
    {
        try
        {
            using var handler = new HttpClientHandler { UseProxy = false };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(2) };
            string json = await client.GetStringAsync("http://127.0.0.1:9090/proxies/AUTO");
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.TryGetProperty("now", out var now) ? now.GetString() ?? "—" : "—";
        }
        catch { return "—"; }
    }

    private static string ReadWatchdogState()
    {
        try
        {
            if (!File.Exists(StateFile)) return "—";
            using var doc = JsonDocument.Parse(File.ReadAllText(StateFile));
            return doc.RootElement.TryGetProperty("status", out var s) ? s.GetString() ?? "—" : "—";
        }
        catch { return "—"; }
    }

    private static async Task<string> CheckHealthAsync()
    {
        string[] urls = ["https://www.youtube.com", "https://api.github.com", "https://api.telegram.org"];
        string mode = ReadMode();

        async Task<bool> ProbeAsync(string url)
        {
            try
            {
                using var handler = new HttpClientHandler();
                if (mode == "proxy")
                {
                    handler.Proxy = new WebProxy("http://127.0.0.1:7890");
                    handler.UseProxy = true;
                }
                else
                {
                    handler.UseProxy = false;
                }

                using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(4) };
                using var request = new HttpRequestMessage(HttpMethod.Head, url);
                using var response = await client.SendAsync(request);
                return (int)response.StatusCode < 500;
            }
            catch
            {
                return false;
            }
        }

        bool[] results = await Task.WhenAll(urls.Select(ProbeAsync));
        return $"{results.Count(x => x)}/3";
    }

    private void ApplyButtonState(string mode, bool running)
    {
        if (_busy)
            return;

        // Exactly the currently active mode button is disabled.
        _proxyMode.Enabled = mode != "proxy";
        _tunMode.Enabled = mode != "tun";
        _offMode.Enabled = mode != "off";

        _restart.Enabled = mode == "proxy" && running;
        _refresh.Enabled = true;
        _test.Enabled = !string.IsNullOrWhiteSpace(_pendingText);
        _checkCoreUpdate.Enabled = true;
        _validateCandidate.Enabled = true;

        bool candidateReady =
            !string.IsNullOrWhiteSpace(_validatedCandidatePath) &&
            File.Exists(_validatedCandidatePath);

        _installValidated.Enabled = candidateReady;
        _testRollback.Enabled = candidateReady;
    }

    private void SetBusy(bool busy, string text)
    {
        _busy = busy;
        _operationValue.Text = text;

        foreach (var b in new[]
        {
            _proxyMode, _tunMode, _offMode, _restart, _refresh,
            _paste, _test, _apply, _updateNow, _checkCoreUpdate, _validateCandidate, _installValidated, _testRollback, _copyDiagnostics, _about
        })
            b.Enabled = !busy;

        if (!busy)
        {
            bool candidateReady =
                !string.IsNullOrWhiteSpace(_validatedCandidatePath) &&
                File.Exists(_validatedCandidatePath);

            _installValidated.Enabled = candidateReady;
            _testRollback.Enabled = candidateReady;
            _copyDiagnostics.Enabled = true;
            _about.Enabled = true;
        }

        UseWaitCursor = busy;
    }

    private static string TrimForMessage(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return "(no diagnostic output)";

        string trimmed = text.Trim();
        return trimmed.Length <= 500 ? trimmed : trimmed[..500] + "...";
    }
}
