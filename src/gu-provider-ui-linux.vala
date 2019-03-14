using AppIndicator;
using Gtk;
using GLib;
using Gee;
using Soup;
using Json;
using Avahi;

Window main_window;
Window add_hub_window;
Gtk.Menu menu;
Gtk.ListStore hub_list_model;
Gtk.ToggleButton auto_mode;
Avahi.Client avahi_client;
GLib.List<Avahi.ServiceResolver> avahi_resolvers;
Indicator indicator;
Gtk.Entry add_hub_ip;
Gtk.Entry add_hub_port;
Gtk.Label provider_status;

ServiceBrowser avahi_service_browser;

const string GU_PROVIDER_PATH = "/home/golem-user/Documents/golem-unlimited/target/debug/gu-provider";
const int CHECK_STATUS_EVERY_MS = 1000;
const string CONFIG_FILE_NAME = "gu_provider-ui-linux.conf";

public bool on_update_status() {
    try {
        string ret;
        Process.spawn_command_line_sync(GU_PROVIDER_PATH + " server status", out ret, null, null);
        indicator.set_icon(ret.index_of("is running") != -1 ? "golemu" : "golemu-red");
        provider_status.set_text("GU Provider Status: " + ret.strip());
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
    auto_mode.active = bool.parse(is_provider_in_auto_mode.strip());

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
        Process.spawn_sync( null,
            { GU_PROVIDER_PATH, "configure", new_val ? "-a" : "-d", (string)node_id, (string)ip_port, (string)host_name },
            null, SpawnFlags.SEARCH_PATH, null, null, null);
        hub_list_model.set(iter, 0, new_val);
    } catch (GLib.Error err) { warning(err.message); }
}

public void on_auto_mode_toggled(Gtk.ToggleButton auto_mode) {
    try {
        Process.spawn_command_line_sync(GU_PROVIDER_PATH + " configure -" + (auto_mode.active ? "A" : "D"), null, null, null);
    } catch (GLib.Error err) { warning(err.message); }
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

public void on_found_new_node(Interface @interface, Protocol protocol, string name, string type, string domain, string hostname, Avahi.Address? address, uint16 port, StringList? txt) {
    if (protocol == Protocol.INET) {
        string ip_str = address.to_string();
        TreeIter iter;
        hub_list_model.append(out iter);
        hub_list_model.set(iter, 1, hostname);
        string ip_port = protocol == Protocol.INET6 ? ("[" + ip_str + "]" + ":" + port.to_string()) : (ip_str + ":" + port.to_string());
        hub_list_model.set(iter, 2, ip_port);
        txt = txt.find("node_id");
        if (txt != null) {
            string key;
            char[] val;
            txt.get_pair(out key, out val);
            hub_list_model.set(iter, 3, (string)val);
            try {
                string is_managed_by_hub;
                Process.spawn_command_line_sync("/home/golem-user/Documents/golem-unlimited/target/debug/gu-provider configure -g "
                    + (string)val, out is_managed_by_hub, null, null);
                hub_list_model.set(iter, 0, bool.parse(is_managed_by_hub.strip()));
            } catch (GLib.Error err) { warning(err.message); }
        } else {
            hub_list_model.set(iter, 3, "");
        }
    }
}

public void on_new_avahi_service (Interface @interface, Protocol protocol, string name, string type, string domain, LookupResultFlags flags) {
    ServiceResolver resolver = new ServiceResolver(Interface.UNSPEC, protocol, name, type, domain, protocol);
    resolver.found.connect(on_found_new_node);
    resolver.failure.connect((err) => { warning(err.message); });
    try {
        resolver.attach(avahi_client);
        avahi_resolvers.append(resolver);
    } catch (Avahi.Error err) { warning(err.message); }
}

void find_hubs_using_avahi() {
    avahi_service_browser = new ServiceBrowser("_gu_hub._tcp");
    avahi_service_browser.new_service.connect(on_new_avahi_service);
    avahi_resolvers = new GLib.List<ServiceResolver>();
    avahi_client = new Client();
    try {
        avahi_client.start();
        avahi_service_browser.attach(avahi_client);
    } catch (Avahi.Error err) { warning(err.message); }
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
