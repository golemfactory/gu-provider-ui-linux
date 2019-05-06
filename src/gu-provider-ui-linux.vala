using AppIndicator;
using Gtk;
using GLib;
using Gee;
using Soup;
using Json;

Window main_window;
Window add_hub_window;
Gtk.Menu menu;
Gtk.ListStore hub_list_model;
Gtk.ToggleButton auto_mode;
Indicator indicator;
Gtk.Entry add_hub_ip;
Gtk.Entry add_hub_port;
Gtk.Label provider_status;
string unixSocketPath;

const string GU_PROVIDER_PATH = "gu-provider"; // ~/Documents/golem-unlimited/target/debug/
const int CHECK_STATUS_EVERY_MS = 1000;
const string CONFIG_FILE_NAME = "gu_provider-ui-linux.conf";

public string? requestHTTPFromUnixSocket(string path, string method, string query) {
    try {
        var client = new SocketClient();
        var connection = client.connect(new UnixSocketAddress(path));
        connection.output_stream.write((method + " " + query + " HTTP/1.0\r\n\r\n").data);
        DataInputStream response = new DataInputStream(connection.input_stream);
        string result = "";
        while (true) {
            string str = response.read_line(null);
            if (str == null) break;
            result = result + str + "\n";
        }
        return result;
    } catch (GLib.Error err) {
        return null;
    }
}

public string? getHTTPBodyFromUnixSocket(string path, string method, string query) {
    var response = requestHTTPFromUnixSocket(path, method, query);
    if (response == null) return null;
    return response.split("\r\n\r\n", 2)[1];
}

public bool on_update_status() {
    var status = getHTTPBodyFromUnixSocket(unixSocketPath, "GET", "/status?timeout=5");
    var json_parser = new Json.Parser();
    try {
        json_parser.load_from_data(status, -1);
        var env = json_parser.get_root().get_object().get_object_member("envs").get_string_member("hostDirect");
        indicator.set_icon(env == "Ready" ? "golemu" : "golemu-red");
        provider_status.set_text("GU Provider Status: " + env);
    } catch (GLib.Error err) { warning(err.message); }
    return true;
}

public void on_configure_menu_activate(Gtk.MenuItem menu) {
    main_window.show_all();
}

public void on_exit_menu_activate(Gtk.MenuItem menu) {
    Process.exit(0);
}

public void on_refresh_hub_list(Gtk.Button button) {
    reload_hub_list();
}

void reload_hub_list() {
    hub_list_model.clear();

    /* check auto/manual mode */
    string is_provider_in_auto_mode;
    try {
        Process.spawn_command_line_sync(GU_PROVIDER_PATH + " configure -g auto", out is_provider_in_auto_mode, null, null);
    } catch (GLib.Error err) { warning(err.message); }
    GLib.SignalHandler.block_by_func(auto_mode, (void*)on_auto_mode_toggled, null);
    auto_mode.active = bool.parse(is_provider_in_auto_mode.strip());
    GLib.SignalHandler.unblock_by_func(auto_mode, (void*)on_auto_mode_toggled, null);

    var json_parser = new Json.Parser();
    string cli_hub_info;

    HashSet<string> all_hubs = new HashSet<string>();

    /* hubs in the lan and their permissions */
    try {
        Process.spawn_command_line_sync(GU_PROVIDER_PATH + " --json lan list -I hub", out cli_hub_info, null, null);
        json_parser.load_from_data(cli_hub_info, -1);
    } catch (GLib.Error err) { warning(err.message); }
    var answer = json_parser.get_root().get_array();
    foreach (var node in answer.get_elements()) {
        Json.Object obj = node.get_object();
        string descr = obj.get_string_member("Description");
        if (descr.index_of("node_id=") == 0) descr = descr.substring(8);
        TreeIter iter;
        hub_list_model.append(out iter);
        hub_list_model.set(iter, 0, false);
        hub_list_model.set(iter, 1, obj.get_string_member("Host name"));
        hub_list_model.set(iter, 2, obj.get_string_member("Addresses"));
        hub_list_model.set(iter, 3, descr);
        try {
            string is_managed_by_hub;
            Process.spawn_command_line_sync(GU_PROVIDER_PATH + " configure -g " + (string)descr, out is_managed_by_hub, null, null);
            hub_list_model.set(iter, 0, bool.parse(is_managed_by_hub.strip()));
            all_hubs.add(descr);
        } catch (GLib.Error err) { warning(err.message); }
    }

    /* saved hubs and their permissions */
    try {
        Process.spawn_command_line_sync(GU_PROVIDER_PATH + " configure -l", out cli_hub_info, null, null);
        json_parser.load_from_data(cli_hub_info, -1);
    } catch (GLib.Error err) { warning(err.message); }
    var saved_hubs = json_parser.get_root().get_array();
    foreach (var node in saved_hubs.get_elements()) {
        Json.Object obj = node.get_object();
        string node_id = obj.get_string_member("node_id");
        if (!all_hubs.contains(node_id)) {
            TreeIter iter;
            hub_list_model.append(out iter);
            hub_list_model.set(iter, 0, false);
            hub_list_model.set(iter, 1, obj.get_string_member("host_name"));
            hub_list_model.set(iter, 2, obj.get_string_member("address"));
            hub_list_model.set(iter, 3, node_id);
            all_hubs.add(node_id);
            try {
                string is_managed_by_hub;
                Process.spawn_command_line_sync(GU_PROVIDER_PATH + " configure -g " + node_id, out is_managed_by_hub, null, null);
                hub_list_model.set(iter, 0, bool.parse(is_managed_by_hub.strip()));
            } catch (GLib.Error err) { warning(err.message); }
        }
    }
}

public void on_hub_selected_toggled(CellRendererToggle toggle, string path) {
    TreeIter iter;
    bool new_val = !toggle.active;
    hub_list_model.get_iter(out iter, new TreePath.from_string(path));
    GLib.Value node_id, ip_port, host_name;
    hub_list_model.get_value(iter, 1, out host_name);
    hub_list_model.get_value(iter, 2, out ip_port);
    hub_list_model.get_value(iter, 3, out node_id);
    try {
        Process.spawn_sync(null,
            { GU_PROVIDER_PATH, "configure", new_val ? "-a" : "-d", (string)node_id, (string)ip_port, (string)host_name },
            null, SpawnFlags.SEARCH_PATH, null, null, null);
        hub_list_model.set(iter, 0, new_val);
    } catch (GLib.Error err) { warning(err.message); }
    try {
        Process.spawn_sync(null,
            { GU_PROVIDER_PATH, "hubs", new_val ? "connect" : "disconnect", (string)ip_port },
            null, SpawnFlags.SEARCH_PATH, null, null, null);
    } catch (GLib.Error err) {
        warning(err.message);
    }
}

public void on_auto_mode_toggled(Gtk.ToggleButton auto_mode) {
    try {
        Process.spawn_command_line_sync(GU_PROVIDER_PATH + " configure -" + (auto_mode.active ? "A" : "D"), null, null, null);
    } catch (GLib.Error err) { warning(err.message); }
    try {
        Process.spawn_sync(null,
            { GU_PROVIDER_PATH, "hubs", auto_mode.active ? "auto" : "manual" },
            null, SpawnFlags.SEARCH_PATH, null, null, null);
    } catch (GLib.Error err) {
        warning(err.message);
    }
}

void show_message(Window window, string message) {
    var dialog = new Gtk.MessageDialog(window, Gtk.DialogFlags.MODAL, Gtk.MessageType.WARNING, Gtk.ButtonsType.OK, message);
    dialog.response.connect((result) => { dialog.destroy(); });
    dialog.show();
}

public bool cancel_add_hub(Gtk.Button button) {
    add_hub_window.hide();
    return true;
}

public bool add_new_hub(Gtk.Button button) {
    var session = new Soup.Session();
    InetAddress ip = new InetAddress.from_string(add_hub_ip.text);
    if (ip == null) { show_message(add_hub_window, "Please enter a valid IP address."); return true; }
    string ip_port = add_hub_ip.text + ":" + add_hub_port.text;
    var message = new Soup.Message("GET", "http://" + ip_port + "/node_id/");
    if (session.send_message(message) != 200) { show_message(add_hub_window, "Cannot connect to " + add_hub_ip.text + "."); return true; }
    string[] hub_info = ((string)message.response_body.data).split(" ");
    try {
        Process.spawn_sync( null,
            { GU_PROVIDER_PATH, "configure", "-a", hub_info[0], (string)ip_port, hub_info[1] },
            null, SpawnFlags.SEARCH_PATH, null, null, null);
    } catch (GLib.Error err) { show_message(add_hub_window, err.message); }
    add_hub_ip.text = "";
    reload_hub_list();
    add_hub_window.hide();
    return true;
}

public bool show_add_hub_window(Gtk.Button button) {
    add_hub_window.show_all();
    return true;
}

public bool on_window_delete_event(Gtk.Window window) {
    window.hide();
    return true;
}

public class GUProviderUI : Gtk.Application {
    Gtk.Builder builder = new Gtk.Builder();
    int num_launched = 0;
    public GUProviderUI() {
        GLib.Object(application_id: "network.golem.gu-provider-ui-linux", flags: ApplicationFlags.FLAGS_NONE);
    }
    protected override void startup() {
        base.startup();
        try {
            builder.add_from_resource("/network/golem/gu-provider-ui-linux/window.glade");
            main_window = builder.get_object("main_window") as Window;
            add_hub_window = builder.get_object("add_hub_window") as Window;
            menu = builder.get_object("menu") as Gtk.Menu;
            hub_list_model = builder.get_object("hub_list_model") as Gtk.ListStore;
            auto_mode = builder.get_object("auto_mode") as Gtk.ToggleButton;
            add_hub_ip = builder.get_object("add_hub_ip") as Gtk.Entry;
            add_hub_port = builder.get_object("add_hub_port") as Gtk.Entry;
            provider_status = builder.get_object("provider_status") as Gtk.Label;
            builder.connect_signals(null);
        } catch (GLib.Error e) {
            stderr.printf("Error while loading GUI: %s\n", e.message);
            Process.exit(1);
        }

        indicator = new Indicator("Golem Unlimited Provider UI", "golemu-red", IndicatorCategory.APPLICATION_STATUS);
        indicator.set_icon("golemu-red");
        indicator.set_status(IndicatorStatus.ACTIVE);
        indicator.set_menu(menu);

        unixSocketPath = "/tmp/gu-provider.socket";

        reload_hub_list();

        /* uncomment to turn on mdns discovery of hub nodes */
        /* find_hubs_using_avahi(); */

        /* periodically check provider status */
        GLib.Timeout.add(CHECK_STATUS_EVERY_MS, on_update_status);

        /* show main window if the config file does not exists, i.e. the app was launched for the first time */
        add_window(main_window);
        bool config_exists = false;
        string config_file_path = GLib.Path.build_filename(GLib.Environment.get_user_config_dir(), CONFIG_FILE_NAME);
        KeyFile config_file = new KeyFile();
        try { if (config_file.load_from_file(config_file_path, NONE)) config_exists = true; } catch (GLib.Error err) {}
        if (!config_exists) {
            try { config_file.save_to_file(config_file_path); } catch (GLib.Error err) { warning(err.message); }
            main_window.show_all();
        }
    }
    protected override void activate() {
        if (num_launched > 0) main_window.show_all();
        ++num_launched;
    }
    public static int main(string[] args) {
        GUProviderUI provider_ui = new GUProviderUI();
        return provider_ui.run(args);
    }
}
