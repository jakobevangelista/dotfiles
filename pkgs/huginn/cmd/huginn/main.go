package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
)

var (
	defaultCloudHypervisor = "cloud-hypervisor"
	defaultVirtiofsd       = "virtiofsd"
	defaultIP              = "ip"
)

const (
	stateRoot             = "/var/lib/huginn"
	instancesRoot         = stateRoot + "/instances"
	runRoot               = "/run/huginn"
	manifestPath          = "/etc/huginn/base-manifest.json"
	dnsmasqLeasesPath     = stateRoot + "/dnsmasq.leases"
	prometheusTargetsRoot = "/var/lib/prometheus-targets"
	bridgeName            = "virbr0"
)

var idPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,11}$`)

type baseManifest struct {
	Kernel  string `json:"kernel"`
	Initrd  string `json:"initrd"`
	System  string `json:"system"`
	Cmdline string `json:"cmdline"`
}

type instanceState struct {
	ID                   string       `json:"id"`
	Name                 string       `json:"name"`
	MAC                  string       `json:"mac"`
	Tap                  string       `json:"tap"`
	IP                   string       `json:"ip,omitempty"`
	Status               string       `json:"status"`
	CloudHypervisorPID   int          `json:"cloudHypervisorPid,omitempty"`
	StoreVirtiofsdPID    int          `json:"storeVirtiofsdPid,omitempty"`
	MetadataVirtiofsdPID int          `json:"metadataVirtiofsdPid,omitempty"`
	CreatedAt            string       `json:"createdAt"`
	UpdatedAt            string       `json:"updatedAt"`
	Manifest             baseManifest `json:"manifest"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "huginn: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	command := "list"
	if len(args) > 0 {
		command = args[0]
		args = args[1:]
	}

	switch command {
	case "create":
		return create(args)
	case "start":
		return start(args)
	case "list":
		return list(args)
	case "status":
		return status(args)
	case "stop":
		return stop(args)
	case "destroy":
		return destroy(args)
	case "logs":
		return logs(args)
	case "help", "--help", "-h":
		usage(os.Stdout)
		return nil
	default:
		usage(os.Stderr)
		return fmt.Errorf("unknown command %q", command)
	}
}

func usage(w io.Writer) {
	fprintf := func(format string, args ...any) { fmt.Fprintf(w, format, args...) }
	fprintf("Usage: huginn <command> [args]\n\n")
	fprintf("Commands:\n")
	fprintf("  create [id]       Start a new VM from the base manifest\n")
	fprintf("  start <id>        Start a stopped VM\n")
	fprintf("  list              List known VMs\n")
	fprintf("  status <id>       Show VM state\n")
	fprintf("  stop <id>         Stop a VM and keep its state directory\n")
	fprintf("  destroy <id>      Stop a VM and remove its state directory\n")
	fprintf("  logs <id> [log]   Print serial, cloud-hypervisor, or virtiofsd logs\n")
}

func create(args []string) error {
	if err := requireRoot(); err != nil {
		return err
	}

	id, err := parseCreateID(args)
	if err != nil {
		return err
	}
	if id == "" {
		id, err = generateID()
		if err != nil {
			return err
		}
	}

	if _, err := os.Stat(instanceDir(id)); err == nil {
		return fmt.Errorf("instance %s already exists", id)
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}

	manifest, err := readManifest()
	if err != nil {
		return err
	}

	now := time.Now().UTC().Format(time.RFC3339)
	state := &instanceState{
		ID:        id,
		Name:      "huginn-" + id,
		MAC:       macForID(id),
		Tap:       "th-" + id,
		Status:    "starting",
		CreatedAt: now,
		UpdatedAt: now,
		Manifest:  manifest,
	}

	if err := makeInstanceDirs(id); err != nil {
		return err
	}

	success := false
	defer func() {
		if !success {
			cleanupRuntime(state)
			_ = os.RemoveAll(instanceDir(id))
		}
	}()

	if err := writeMetadata(state); err != nil {
		return err
	}
	if err := startRuntime(state); err != nil {
		return err
	}

	success = true
	printStarted(state)
	return nil
}

func start(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: huginn start <id>")
	}
	if err := requireRoot(); err != nil {
		return err
	}

	state, err := loadState(args[0])
	if err != nil {
		return err
	}
	if runtimeStatus(state) == "running" {
		return fmt.Errorf("instance %s is already running", state.ID)
	}

	success := false
	defer func() {
		if !success {
			cleanupRuntime(state)
			_ = markStopped(state)
		}
	}()

	manifest, err := readManifest()
	if err != nil {
		return err
	}
	state.Manifest = manifest

	cleanupRuntime(state)
	if err := makeInstanceDirs(state.ID); err != nil {
		return err
	}
	if err := writeMetadata(state); err != nil {
		return err
	}
	if err := startRuntime(state); err != nil {
		return err
	}

	success = true
	printStarted(state)
	return nil
}

func parseCreateID(args []string) (string, error) {
	if len(args) == 0 {
		return "", nil
	}
	if len(args) == 2 && args[0] == "--name" {
		return normalizeID(args[1])
	}
	if len(args) == 1 {
		return normalizeID(args[0])
	}
	return "", fmt.Errorf("usage: huginn create [id]")
}

func list(args []string) error {
	if len(args) != 0 {
		return fmt.Errorf("usage: huginn list")
	}

	entries, err := os.ReadDir(instancesRoot)
	if errors.Is(err, os.ErrNotExist) {
		fmt.Printf("%-12s %-9s %-15s %-17s %s\n", "id", "state", "ip", "mac", "name")
		return nil
	}
	if err != nil {
		return err
	}

	ids := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			ids = append(ids, entry.Name())
		}
	}
	sort.Strings(ids)

	fmt.Printf("%-12s %-9s %-15s %-17s %s\n", "id", "state", "ip", "mac", "name")
	for _, id := range ids {
		state, err := loadStateByID(id)
		if err != nil {
			fmt.Printf("%-12s %-9s %-15s %-17s %s\n", id, "invalid", "-", "-", "-")
			continue
		}
		printStateRow(state)
	}
	return nil
}

func status(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: huginn status <id>")
	}
	state, err := loadState(args[0])
	if err != nil {
		return err
	}

	state.Status = runtimeStatus(state)
	if ip, err := leaseForMAC(state.MAC); err == nil && ip != "" {
		state.IP = ip
	}

	fmt.Printf("id: %s\n", state.ID)
	fmt.Printf("name: %s\n", state.Name)
	fmt.Printf("status: %s\n", state.Status)
	fmt.Printf("ip: %s\n", valueOrDash(state.IP))
	fmt.Printf("mac: %s\n", state.MAC)
	fmt.Printf("tap: %s\n", state.Tap)
	fmt.Printf("cloud-hypervisor pid: %s\n", pidOrDash(state.CloudHypervisorPID))
	fmt.Printf("store virtiofsd pid: %s\n", pidOrDash(state.StoreVirtiofsdPID))
	fmt.Printf("metadata virtiofsd pid: %s\n", pidOrDash(state.MetadataVirtiofsdPID))
	fmt.Printf("instance dir: %s\n", instanceDir(state.ID))
	fmt.Printf("runtime dir: %s\n", runtimeDir(state.ID))
	fmt.Printf("target file: %s\n", prometheusTargetPath(state))
	return nil
}

func stop(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: huginn stop <id>")
	}
	if err := requireRoot(); err != nil {
		return err
	}
	state, err := loadState(args[0])
	if err != nil {
		return err
	}
	if err := stopInstance(state); err != nil {
		return err
	}
	fmt.Printf("stopped %s\n", state.Name)
	return nil
}

func destroy(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: huginn destroy <id>")
	}
	if err := requireRoot(); err != nil {
		return err
	}
	state, err := loadState(args[0])
	if err != nil {
		return err
	}
	if err := stopInstance(state); err != nil {
		return err
	}
	if err := os.RemoveAll(instanceDir(state.ID)); err != nil {
		return err
	}
	fmt.Printf("destroyed %s\n", state.Name)
	return nil
}

func logs(args []string) error {
	if len(args) < 1 || len(args) > 2 {
		return fmt.Errorf("usage: huginn logs <id> [serial|cloud-hypervisor|virtiofsd-store|virtiofsd-metadata]")
	}
	state, err := loadState(args[0])
	if err != nil {
		return err
	}

	logName := "serial"
	if len(args) == 2 {
		logName = args[1]
	}

	path := filepath.Join(logsDir(state.ID), logName+".log")
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = io.Copy(os.Stdout, file)
	return err
}

func readManifest() (baseManifest, error) {
	var manifest baseManifest
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return manifest, err
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return manifest, err
	}
	if manifest.Kernel == "" || manifest.Initrd == "" || manifest.System == "" || manifest.Cmdline == "" {
		return manifest, fmt.Errorf("%s is missing required fields", manifestPath)
	}
	return manifest, nil
}

func makeInstanceDirs(id string) error {
	for _, path := range []string{instanceDir(id), metadataDir(id), logsDir(id), runtimeDir(id)} {
		if err := os.MkdirAll(path, 0755); err != nil {
			return err
		}
	}
	return nil
}

func writeMetadata(state *instanceState) error {
	files := map[string]string{
		"instance-id": state.ID + "\n",
		"hostname":    state.Name + "\n",
		"mac":         state.MAC + "\n",
		"tap":         state.Tap + "\n",
	}
	if key, err := os.ReadFile("/home/jakob/.ssh/id_ed25519.pub"); err == nil {
		files["ssh-authorized-keys"] = strings.TrimSpace(string(key)) + "\n"
	}
	for name, value := range files {
		if err := os.WriteFile(filepath.Join(metadataDir(state.ID), name), []byte(value), 0644); err != nil {
			return err
		}
	}
	return nil
}

func startRuntime(state *instanceState) error {
	state.Status = "starting"
	state.IP = ""
	state.CloudHypervisorPID = 0
	state.StoreVirtiofsdPID = 0
	state.MetadataVirtiofsdPID = 0
	state.UpdatedAt = time.Now().UTC().Format(time.RFC3339)

	if err := setupTap(state.Tap); err != nil {
		return err
	}

	storePID, err := startVirtiofsd(state, "store", "/nix/store", roStoreSocket(state.ID), true)
	if err != nil {
		return err
	}
	state.StoreVirtiofsdPID = storePID

	metadataPID, err := startVirtiofsd(state, "metadata", metadataDir(state.ID), metadataSocket(state.ID), false)
	if err != nil {
		return err
	}
	state.MetadataVirtiofsdPID = metadataPID

	cloudHypervisorPID, err := startCloudHypervisor(state)
	if err != nil {
		return err
	}
	state.CloudHypervisorPID = cloudHypervisorPID
	state.Status = "running"
	state.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	if err := writeState(state); err != nil {
		return err
	}

	if err := waitForSocket(apiSocket(state.ID), cloudHypervisorPID, 10*time.Second); err != nil {
		return err
	}

	if ip, err := waitForLease(state.MAC, 75*time.Second); err == nil && ip != "" {
		state.IP = ip
		state.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
		if err := writeState(state); err != nil {
			return err
		}
		if err := writePrometheusTarget(state); err != nil {
			return err
		}
	} else {
		fmt.Fprintf(os.Stderr, "huginn: warning: started %s but no DHCP lease appeared yet\n", state.Name)
	}

	return nil
}

func setupTap(name string) error {
	if err := runIP("link", "show", "dev", name); err == nil {
		return fmt.Errorf("tap %s already exists", name)
	}
	if err := runIP("tuntap", "add", "dev", name, "mode", "tap"); err != nil {
		return err
	}
	if err := runIP("link", "set", "dev", name, "master", bridgeName); err != nil {
		_ = deleteTap(name)
		return err
	}
	if err := runIP("link", "set", "dev", name, "up"); err != nil {
		_ = deleteTap(name)
		return err
	}
	return nil
}

func deleteTap(name string) error {
	return runIP("link", "delete", "dev", name)
}

func runIP(args ...string) error {
	cmd := exec.Command(defaultIP, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return nil
}

func startVirtiofsd(state *instanceState, label, sharedDir, socketPath string, readonly bool) (int, error) {
	args := []string{
		"--shared-dir", sharedDir,
		"--socket-path", socketPath,
		"--cache", "auto",
		"--posix-acl",
		"--xattr",
	}
	if readonly {
		args = append(args, "--readonly")
	}

	pid, err := startProcess(defaultVirtiofsd, args, filepath.Join(logsDir(state.ID), "virtiofsd-"+label+".log"))
	if err != nil {
		return 0, err
	}
	if err := waitForSocket(socketPath, pid, 10*time.Second); err != nil {
		_ = killProcessGroup(pid, "virtiofsd")
		return 0, err
	}
	return pid, nil
}

func startCloudHypervisor(state *instanceState) (int, error) {
	args := []string{
		"--kernel", state.Manifest.Kernel,
		"--initramfs", state.Manifest.Initrd,
		"--cmdline", state.Manifest.Cmdline,
		"--cpus", "boot=2",
		"--memory", "size=6144M,shared=on",
		"--fs", "tag=ro-store,socket=" + roStoreSocket(state.ID), "tag=metadata,socket=" + metadataSocket(state.ID),
		"--net", "tap=" + state.Tap + ",mac=" + state.MAC,
		"--api-socket", "path=" + apiSocket(state.ID),
		"--serial", "file=" + filepath.Join(logsDir(state.ID), "serial.log"),
		"--console", "off",
		"--log-file", filepath.Join(logsDir(state.ID), "cloud-hypervisor.log"),
		"--seccomp", "true",
		"--watchdog",
	}
	return startProcess(defaultCloudHypervisor, args, filepath.Join(logsDir(state.ID), "cloud-hypervisor.stderr.log"))
}

func startProcess(path string, args []string, logPath string) (int, error) {
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return 0, err
	}
	defer logFile.Close()

	cmd := exec.Command(path, args...)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	go func() { _ = cmd.Wait() }()
	return cmd.Process.Pid, nil
}

func waitForSocket(path string, pid int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if info, err := os.Stat(path); err == nil && info.Mode()&os.ModeSocket != 0 {
			return nil
		}
		if !processAlive(pid) {
			return fmt.Errorf("process %d exited before socket %s appeared", pid, path)
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for socket %s", path)
}

func waitForLease(mac string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		ip, err := leaseForMAC(mac)
		if err == nil && ip != "" {
			return ip, nil
		}
		time.Sleep(time.Second)
	}
	return "", fmt.Errorf("timed out waiting for DHCP lease for %s", mac)
}

func leaseForMAC(mac string) (string, error) {
	data, err := os.ReadFile(dnsmasqLeasesPath)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 3 && strings.EqualFold(fields[1], mac) {
			return fields[2], nil
		}
	}
	return "", nil
}

func writePrometheusTarget(state *instanceState) error {
	if state.IP == "" {
		return nil
	}
	payload := []map[string]any{
		{
			"targets": []string{state.IP + ":9100"},
			"labels": map[string]string{
				"job":      "huginn",
				"instance": state.Name,
			},
		},
	}
	if err := os.MkdirAll(prometheusTargetsRoot, 0755); err != nil {
		return err
	}
	return writeJSONAtomic(prometheusTargetPath(state), payload, 0644)
}

func stopInstance(state *instanceState) error {
	cleanupRuntime(state)
	return markStopped(state)
}

func markStopped(state *instanceState) error {
	state.Status = "stopped"
	state.IP = ""
	state.CloudHypervisorPID = 0
	state.StoreVirtiofsdPID = 0
	state.MetadataVirtiofsdPID = 0
	state.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	return writeState(state)
}

func printStarted(state *instanceState) {
	if state.IP != "" {
		fmt.Printf("started %s %s\n", state.Name, state.IP)
	} else {
		fmt.Printf("started %s\n", state.Name)
	}
}

func cleanupRuntime(state *instanceState) {
	_ = os.Remove(prometheusTargetPath(state))
	_ = killProcessGroup(state.CloudHypervisorPID, "cloud-hypervisor")
	_ = killProcessGroup(state.StoreVirtiofsdPID, "virtiofsd")
	_ = killProcessGroup(state.MetadataVirtiofsdPID, "virtiofsd")
	_ = deleteTap(state.Tap)
	_ = os.RemoveAll(runtimeDir(state.ID))
}

func killProcessGroup(pid int, expectedCommand string) error {
	if pid <= 0 || !processAlive(pid) || !processMatches(pid, expectedCommand) {
		return nil
	}
	if err := syscall.Kill(-pid, syscall.SIGTERM); err != nil && !errors.Is(err, syscall.ESRCH) {
		_ = syscall.Kill(pid, syscall.SIGTERM)
	}
	if waitForExit(pid, 10*time.Second) {
		return nil
	}
	if err := syscall.Kill(-pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) {
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
	waitForExit(pid, 5*time.Second)
	return nil
}

func waitForExit(pid int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if !processAlive(pid) {
			return true
		}
		time.Sleep(100 * time.Millisecond)
	}
	return !processAlive(pid)
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	if err != nil && !errors.Is(err, syscall.EPERM) {
		return false
	}

	stat, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return false
	}
	fields := strings.Fields(string(stat))
	if len(fields) >= 3 && fields[2] == "Z" {
		return false
	}

	return true
}

func processMatches(pid int, expectedCommand string) bool {
	if expectedCommand == "" {
		return true
	}
	cmdline, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return false
	}
	return strings.Contains(strings.ReplaceAll(string(cmdline), "\x00", " "), expectedCommand)
}

func printStateRow(state *instanceState) {
	status := runtimeStatus(state)
	ip := state.IP
	if leaseIP, err := leaseForMAC(state.MAC); err == nil && leaseIP != "" {
		ip = leaseIP
	}
	fmt.Printf("%-12s %-9s %-15s %-17s %s\n", state.ID, status, valueOrDash(ip), state.MAC, state.Name)
}

func runtimeStatus(state *instanceState) string {
	if processAlive(state.CloudHypervisorPID) && processMatches(state.CloudHypervisorPID, "cloud-hypervisor") {
		return "running"
	}
	if state.Status == "starting" || state.Status == "running" {
		return "stopped"
	}
	return state.Status
}

func loadState(rawID string) (*instanceState, error) {
	id, err := normalizeID(rawID)
	if err != nil {
		return nil, err
	}
	return loadStateByID(id)
}

func loadStateByID(id string) (*instanceState, error) {
	data, err := os.ReadFile(filepath.Join(instanceDir(id), "state.json"))
	if err != nil {
		return nil, err
	}
	var state instanceState
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, err
	}
	if state.ID == "" {
		state.ID = id
	}
	if state.Name == "" {
		state.Name = "huginn-" + state.ID
	}
	if state.Tap == "" {
		state.Tap = "th-" + state.ID
	}
	return &state, nil
}

func writeState(state *instanceState) error {
	return writeJSONAtomic(filepath.Join(instanceDir(state.ID), "state.json"), state, 0644)
}

func writeJSONAtomic(path string, value any, perm os.FileMode) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func requireRoot() error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("run this command with sudo")
	}
	return nil
}

func generateID() (string, error) {
	for range 20 {
		buf := make([]byte, 4)
		if _, err := rand.Read(buf); err != nil {
			return "", err
		}
		id := hex.EncodeToString(buf)
		if _, err := os.Stat(instanceDir(id)); errors.Is(err, os.ErrNotExist) {
			return id, nil
		}
	}
	return "", fmt.Errorf("failed to allocate an unused instance id")
}

func normalizeID(raw string) (string, error) {
	id := strings.TrimPrefix(strings.TrimSpace(raw), "huginn-")
	if !idPattern.MatchString(id) {
		return "", fmt.Errorf("invalid id %q: use 1-12 lowercase letters, digits, or hyphens", raw)
	}
	return id, nil
}

func macForID(id string) string {
	sum := sha256.Sum256([]byte("huginn-" + id))
	return fmt.Sprintf("02:00:00:%02x:%02x:%02x", sum[0], sum[1], sum[2])
}

func instanceDir(id string) string { return filepath.Join(instancesRoot, id) }
func metadataDir(id string) string { return filepath.Join(instanceDir(id), "metadata") }
func logsDir(id string) string     { return filepath.Join(instanceDir(id), "logs") }
func runtimeDir(id string) string  { return filepath.Join(runRoot, id) }

func apiSocket(id string) string      { return filepath.Join(runtimeDir(id), "ch.sock") }
func roStoreSocket(id string) string  { return filepath.Join(runtimeDir(id), "ro-store.sock") }
func metadataSocket(id string) string { return filepath.Join(runtimeDir(id), "metadata.sock") }

func prometheusTargetPath(state *instanceState) string {
	return filepath.Join(prometheusTargetsRoot, state.Name+".json")
}

func valueOrDash(value string) string {
	if value == "" {
		return "-"
	}
	return value
}

func pidOrDash(pid int) string {
	if pid <= 0 {
		return "-"
	}
	return fmt.Sprintf("%d", pid)
}
