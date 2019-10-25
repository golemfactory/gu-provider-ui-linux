using AppIndicator;
using Gtk;
using GLib;
using Soup;
using Json;

Window main_window;
Window add_hub_window;
Gtk.Menu menu;
Gtk.ListStore hub_list_model;
Gtk.ListStore connection_types;
Gtk.ComboBox auto_mode;
Gtk.Box upper_row;
Gtk.TreeView hub_list;
Indicator indicator;
Gtk.Entry add_hub_ip;
Gtk.Entry add_hub_port;
Gtk.Label provider_status;
Gtk.CheckMenuItem launch_at_login_menu;
string unixSocketPath;
bool connected;

const int CHECK_STATUS_EVERY_MS = 1000;
const string CONFIG_FILE_NAME = "gu_provider-ui-linux.conf";
const string SOCKET_PATH_GLOBAL = "/var/run/golemu/gu-provider.socket";
const string SOCKET_PATH_USER_HOME = ".local/share/golemunlimited/run/gu-provider.socket";
const string SOCKET_PATH_BINARY_DIR = "gu-data/run/gu-provider.socket";
const string DESKTOP_FILE_NAME = "gu-provider-ui-linux.desktop";

public string? requestHTTPFromUnixSocket(string path, string method, string query, string body) {
    try {
        var client = new SocketClient();
        var connection = client.connect(new UnixSocketAddress(path));
        var additional_headers = "";
        if (body != "") {
            additional_headers += "Content-length: " + body.data.length.to_string() + "\r\n";
            additional_headers += "Content-type: application/json\r\n";
        }
        connection.output_stream.write((method + " " + query + " HTTP/1.0\r\n" + additional_headers + "\r\n" + body).data);
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

public string? getHTTPResultFromUnixSocket(string path, string method, string query, string body) {
    var response = requestHTTPFromUnixSocket(path, method, query, body);
    if (response == null) return null;
    return response.split("\r\n\r\n", 2)[1];
}

void update_connection_status() {
    if (!main_window.is_visible()) return;
    try {
        HashTable<string, string> hub_statuses = new HashTable<string, string>(str_hash, str_equal);
        var json_parser = new Json.Parser();
        var conn_list = getHTTPResultFromUnixSocket(unixSocketPath, "GET", "/connections/list/all", "");
        if (conn_list != null) {
            json_parser.load_from_data(conn_list, -1);
            foreach (var hub in json_parser.get_root().get_array().get_elements()) {
                var cols = hub.get_array();
                hub_statuses.set(cols.get_string_element(0), cols.get_string_element(1));
            }
            int n = hub_list_model.iter_n_children(null);
            for (int i = 0; i < n; ++i) {
                TreeIter iter;
                GLib.Value ip, status;
                hub_list_model.get_iter_from_string(out iter, i.to_string());
                hub_list_model.get_value(iter, 3, out ip);
                hub_list_model.get_value(iter, 1, out status);
                var new_status = hub_statuses.contains((string)ip) ? hub_statuses.get((string)ip) : "-";
                if (!(status.get_string() == new_status)) { hub_list_model.set(iter, 1, new_status); }
            }
        }
    } catch (GLib.Error err) {}
}

public bool on_update_status() {
    var status = getHTTPResultFromUnixSocket(unixSocketPath, "GET", "/status?timeout=5", "");
    if (status != null) {
        var json_parser = new Json.Parser();
        try {
            json_parser.load_from_data(status, -1);
            string status_text = "";
            var envs = json_parser.get_root().get_object().get_object_member("envs");
            var envNames = envs.get_members();
            bool ready = false;
            foreach (string key in envNames) {
                string value = envs.get_string_member(key);
                status_text = status_text + (status_text == "" ? "" : ", ") + key + ": " + value;
                if (value != "Disabled") { ready = true; }
            }
            if (status_text == "") status_text = "No Valid Runtime Environment";
            if (ready != connected) {
                reload_hub_list();
                indicator.set_icon(ready ? "golemu" : "golemu-red");
            }
            status_text = "GU Provider Status: " + status_text;
            if (provider_status.get_text() != status_text) { provider_status.set_text(status_text); }
            if (ready) {
                if (upper_row.get_sensitive() == false) { upper_row.set_sensitive(true); hub_list.set_sensitive(true); }
                update_connection_status();
            } else {
                if (upper_row.get_sensitive() == true) { upper_row.set_sensitive(false); hub_list.set_sensitive(false); }
            }
            connected = ready;
        } catch (GLib.Error err) {
            indicator.set_icon("golemu-red");
            connected = false;
            provider_status.set_text("GU Provider Status: Invalid Answer");
            warning("Invalid answer from the provider: " + err.message);
            if (hub_list_model.iter_n_children(null) > 0) { hub_list_model.clear(); }
            if (upper_row.get_sensitive() == true) { upper_row.set_sensitive(false); hub_list.set_sensitive(false); }
        }
    } else {
        indicator.set_icon("golemu-red");
        connected = false;
        provider_status.set_text("GU Provider Status: Cannot Connect");
        warning("No answer from the provider (status).");
        if (hub_list_model.iter_n_children(null) > 0) { hub_list_model.clear(); }
        if (upper_row.get_sensitive() == true) { upper_row.set_sensitive(false); hub_list.set_sensitive(false); }
    }
    return true;
}

public void on_launch_at_login_menu_toggled(Gtk.CheckMenuItem menu) {
    var launch_at_login = menu.get_active();
    string autostart_file_path = GLib.Path.build_filename(Environment.get_user_config_dir(), "autostart/" + DESKTOP_FILE_NAME);
    if (launch_at_login) {
        string[] search_dirs = Environment.get_system_data_dirs();
        foreach (var dir in search_dirs) {
            string path = GLib.Path.build_filename(dir, "applications/" + DESKTOP_FILE_NAME);
            var desktop_file = File.new_for_path(path);
            if (desktop_file.query_exists()) {
                try {
                    desktop_file.copy(File.new_for_path(autostart_file_path), 0, null, null);
                } catch (GLib.Error err) {
                    warning(err.message);
                }
                break;
            }
        }
    } else {
        try { File.new_for_path(autostart_file_path).delete(); } catch (GLib.Error err) { warning(err.message); }
    }
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

string connection_mode_label(string i) {
    if (i == "false") i = "0"; else if (i == "true") i = "2";
    GLib.Value mode;
    TreeIter mode_iter;
    connection_types.get_iter_from_string(out mode_iter, i);
    connection_types.get_value(mode_iter, 0, out mode);
    return (string)mode;
}

void reload_hub_list() {
    hub_list_model.clear();

    /* check auto/manual mode */
    string is_provider_in_auto_mode;
    is_provider_in_auto_mode = getHTTPResultFromUnixSocket(unixSocketPath, "GET", "/nodes/auto", "");
    if (is_provider_in_auto_mode == null) { warning("No answer from the provider (hub list)."); return; }
    GLib.SignalHandler.block_by_func(auto_mode, (void*)on_auto_mode_changed, null);
    auto_mode.set_active(int.parse(is_provider_in_auto_mode.strip()));
    GLib.SignalHandler.unblock_by_func(auto_mode, (void*)on_auto_mode_changed, null);

    var json_parser = new Json.Parser();
    string cli_hub_info;

    HashTable<string, bool> all_hubs = new HashTable<string, bool>(str_hash, str_equal);

    /* hubs in the lan and their permissions */
    try {
        cli_hub_info = getHTTPResultFromUnixSocket(unixSocketPath, "GET", "/lan/list", "");
        json_parser.load_from_data(cli_hub_info, -1);
    } catch (GLib.Error err) { warning(err.message); }
    var answer = json_parser.get_root().get_array();
    foreach (var node in answer.get_elements()) {
        Json.Object obj = node.get_object();
        string descr = obj.get_string_member("Description");
        if (descr.index_of("node_id=") == 0 && descr.length >= 8 + 42) descr = descr.substring(8, 42);
        TreeIter iter;
        hub_list_model.append(out iter);
        string is_managed_by_hub = getHTTPResultFromUnixSocket(unixSocketPath, "GET", "/nodes/" + (string)descr, "");
        string mode = connection_mode_label(is_managed_by_hub.strip());
        hub_list_model.set(iter, 0, mode);
        hub_list_model.set(iter, 1, "-");
        hub_list_model.set(iter, 2, obj.get_string_member("Host name"));
        hub_list_model.set(iter, 3, obj.get_string_member("Addresses"));
        hub_list_model.set(iter, 4, descr);
        all_hubs.set(descr, true);
    }

    /* saved hubs and their permissions */
    try {
        cli_hub_info = getHTTPResultFromUnixSocket(unixSocketPath, "GET", "/nodes?saved", "");
        json_parser.load_from_data(cli_hub_info, -1);
    } catch (GLib.Error err) { warning(err.message); }
    var saved_hubs = json_parser.get_root().get_array();
    foreach (var node in saved_hubs.get_elements()) {
        Json.Object obj = node.get_object();
        string node_id = obj.get_string_member("node_id");
        if (!all_hubs.contains(node_id)) {
            TreeIter iter;
            hub_list_model.append(out iter);
            string is_managed_by_hub = getHTTPResultFromUnixSocket(unixSocketPath, "GET", "/nodes/" + node_id, "");
            string mode = connection_mode_label(is_managed_by_hub.strip());
            hub_list_model.set(iter, 0, mode);
            hub_list_model.set(iter, 1, "-");
            hub_list_model.set(iter, 2, obj.get_string_member("host_name"));
            hub_list_model.set(iter, 3, obj.get_string_member("address"));
            hub_list_model.set(iter, 4, node_id);
            all_hubs.set(node_id, true);
        }
    }
}

int get_selected_value_index(Gtk.ListStore store, string text) {
    int n = connection_types.iter_n_children(null);
    for (int i = 0; i < n; ++i) {
       GLib.Value val;
       TreeIter iter;
       connection_types.get_iter_from_string(out iter, i.to_string());
       connection_types.get_value(iter, 0, out val);
       if (val.get_string() == text) { return i; }
    }
    stderr.printf("Selected value not found.\n");
    return -1;
}

public void on_hub_connection_changed(CellRendererText renderer, string path, string text) {
    GLib.Value node_id, ip_port, host_name;
    TreeIter hub_list_iter;
    hub_list_model.get_iter(out hub_list_iter, new TreePath.from_string(path));
    hub_list_model.get_value(hub_list_iter, 2, out host_name);
    hub_list_model.get_value(hub_list_iter, 3, out ip_port);
    hub_list_model.get_value(hub_list_iter, 4, out node_id);

    int v = get_selected_value_index(connection_types, text);
    getHTTPResultFromUnixSocket(unixSocketPath, v != 0 ? "PUT" : "DELETE",
        "/nodes/" + (string)node_id, json_for_ip_host_name_access_level((string)ip_port, (string)host_name, v));
    getHTTPResultFromUnixSocket(unixSocketPath, "POST",
                                "/connections/" + (v != 0 ? "connect" : "disconnect") + "?save=1",
                                "[\"" + (string)ip_port + "\"]");

    hub_list_model.set_value(hub_list_iter, 0, text);
}

public void on_auto_mode_changed(Gtk.ComboBox combo) {
    getHTTPResultFromUnixSocket(unixSocketPath, combo.get_active() != 0 ? "PUT" : "DELETE", "/nodes/auto",
                                json_for_ip_host_name_access_level(null, null, combo.get_active()));
    getHTTPResultFromUnixSocket(unixSocketPath, "PUT", "/connections/mode/" + (combo.get_active() != 0 ? "auto" : "manual") + "?save=1", "");
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

public string json_for_ip_host_name_access_level(string? address, string? host_name, int access_level) {
    Json.Builder b = new Json.Builder();
    b.begin_object();
    if (address != null) { b.set_member_name("address"); b.add_string_value(address); }
    if (host_name != null) { b.set_member_name("hostName"); b.add_string_value(host_name); }
    b.set_member_name("accessLevel");
    b.add_int_value(access_level);
    b.end_object();
    Json.Generator g = new Json.Generator();
    g.set_root(b.get_root());
    return g.to_data(null);
}

public bool add_new_hub(Gtk.Button button) {
    var session = new Soup.Session();
    InetAddress ip = new InetAddress.from_string(add_hub_ip.text);
    if (ip == null) { show_message(add_hub_window, "Please enter a valid IP address."); return true; }
    string ip_port = add_hub_ip.text + ":" + add_hub_port.text;
    var message = new Soup.Message("GET", "http://" + ip_port + "/node_id/");
    if (session.send_message(message) != 200) { show_message(add_hub_window, "Cannot connect to " + add_hub_ip.text + "."); return true; }
    string[] hub_info = ((string)message.response_body.data).split(" ");
    getHTTPResultFromUnixSocket(unixSocketPath, "PUT", "/nodes/" + hub_info[0], json_for_ip_host_name_access_level(ip_port, hub_info[1], 1));
    getHTTPResultFromUnixSocket(unixSocketPath, "POST", "/connections/connect?save=1", "[\"" + (string)ip_port + "\"]");
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
            connection_types = builder.get_object("connection_types") as Gtk.ListStore;
            auto_mode = builder.get_object("auto_mode") as Gtk.ComboBox;
            upper_row = builder.get_object("upper_row") as Gtk.Box;
            hub_list = builder.get_object("hub_list") as Gtk.TreeView;
            add_hub_ip = builder.get_object("add_hub_ip") as Gtk.Entry;
            add_hub_port = builder.get_object("add_hub_port") as Gtk.Entry;
            provider_status = builder.get_object("provider_status") as Gtk.Label;
            launch_at_login_menu = builder.get_object("launch_at_login_menu") as Gtk.CheckMenuItem;
            builder.connect_signals(null);
        } catch (GLib.Error e) {
            stderr.printf("Error while loading GUI: %s\n", e.message);
            Process.exit(1);
        }

        connected = false;
        indicator = new Indicator("Golem Unlimited Provider UI", "golemu-red", IndicatorCategory.APPLICATION_STATUS);
        indicator.set_icon("golemu-red");
        indicator.set_status(IndicatorStatus.ACTIVE);
        indicator.set_menu(menu);

        string autostart_file_path = GLib.Path.build_filename(Environment.get_user_config_dir(), "autostart/" + DESKTOP_FILE_NAME);
        if (File.new_for_path(autostart_file_path).query_exists()) {
            GLib.SignalHandler.block_by_func(launch_at_login_menu, (void*)on_launch_at_login_menu_toggled, null);
            launch_at_login_menu.set_active(true);
            GLib.SignalHandler.unblock_by_func(launch_at_login_menu, (void*)on_launch_at_login_menu_toggled, null);
        }

        var local_path = GLib.Path.build_filename(Environment.get_home_dir(), SOCKET_PATH_USER_HOME);
        string? exec_path;
        try {
            exec_path = GLib.Path.get_dirname(GLib.FileUtils.read_link("/proc/self/exe"));
        } catch (GLib.FileError e) {
            exec_path = null;
        }
        var exec_socket_path = exec_path != null ? GLib.Path.build_filename(exec_path, SOCKET_PATH_BINARY_DIR) : null;
        if (exec_socket_path != null && File.new_for_path(exec_socket_path).query_exists()) {
            unixSocketPath = exec_socket_path;
        } else if (File.new_for_path(local_path).query_exists()) {
            unixSocketPath = local_path;
        } else {
            unixSocketPath = SOCKET_PATH_GLOBAL;
        }
        stderr.printf("Using socket: %s\n", unixSocketPath);

        reload_hub_list();

        /* periodically check provider status */
        GLib.Timeout.add(CHECK_STATUS_EVERY_MS, on_update_status);

        /* show main window if the config file does not exists, i.e. the app was launched for the first time, or in portable mode */
        add_window(main_window);
        bool config_exists = false;
        string config_file_path = GLib.Path.build_filename(Environment.get_user_config_dir(), CONFIG_FILE_NAME);
        KeyFile config_file = new KeyFile();
        try { if (config_file.load_from_file(config_file_path, KeyFileFlags.NONE)) config_exists = true; } catch (GLib.Error err) {}
        if (!config_exists) {
            try { config_file.save_to_file(config_file_path); } catch (GLib.Error err) { warning(err.message); }
            main_window.show_all();
        } else if (unixSocketPath == exec_socket_path) {
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
