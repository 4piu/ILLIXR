#include "plugin.hpp"

#include <chrono>

using namespace ILLIXR;

// Real kernel-measured TCP diagnostics (see network::TCPSocket::get_tcp_info), sampled
// periodically off the single network thread so the network doesn't need its own timer/thread.
// Distinct from the payload_bytes/latency-derived throughput approximation in
// scripts/analyze_metrics.py -- see notes/sev_benchmark_extended_metrics_plan.md.
const record_header _tcp_socket_stats_header{
    "tcp_socket_stats",
    {
        {"wall_time", typeid(std::size_t)},
        {"rtt_us", typeid(std::size_t)},
        {"rttvar_us", typeid(std::size_t)},
        {"retransmits", typeid(std::size_t)},
        {"total_retrans", typeid(std::size_t)},
        {"snd_cwnd", typeid(std::size_t)},
        {"unacked", typeid(std::size_t)},
    }};

// Per-message wire-frame size (8-byte header + topic name + payload), both directions -- larger
// than the serialized-payload-only payload_bytes already logged by offload_vio_uplink/downlink.
const record_header _tcp_frame_header{
    "tcp_frame",
    {
        {"wall_time", typeid(std::size_t)},
        {"direction", typeid(std::string)},
        {"topic_name", typeid(std::string)},
        {"wire_bytes", typeid(std::size_t)},
    }};

namespace {
std::size_t now_ns() {
    return static_cast<std::size_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}
} // namespace

tcp_network_backend::tcp_network_backend(const std::string& name_, phonebook* pb_)
    : plugin(name_, pb_)
    , switchboard_{pb_->lookup_impl<switchboard>()} {
    // read environment variables
    if (const char* val = switchboard_->get_env_char("ILLIXR_TCP_SERVER_IP")) {
        server_ip_ = val;
        spdlog::get("illixr")->info("[tcp_network_backend] Using TCP server IP {}", server_ip_);
    }

    if (const char* val = switchboard_->get_env_char("ILLIXR_TCP_SERVER_PORT")) {
        server_port_ = std::stoi(val);
        spdlog::get("illixr")->info("[tcp_network_backend] Using TCP server port {}", server_port_);
    }

    if (const char* val = switchboard_->get_env_char("ILLIXR_TCP_CLIENT_IP")) {
        client_ip_ = val;
        spdlog::get("illixr")->info("[tcp_network_backend] Using TCP client IP {}", client_ip_);
    }

    if (const char* val = switchboard_->get_env_char("ILLIXR_TCP_CLIENT_PORT")) {
        client_port_ = std::stoi(val);
        spdlog::get("illixr")->info("[tcp_network_backend] Using TCP client port {}", client_port_);
    }

    if (const char* val = switchboard_->get_env_char("ILLIXR_IS_CLIENT")) {
        is_client_ = std::stoi(val);
        spdlog::get("illixr")->info("[tcp_network_backend] Is client: {}", is_client_);
    }

    // ILLIXR_TCP_SERVER_IP/PORT are required for both roles: the server binds to them and the
    // client connects to them. ILLIXR_IS_CLIENT selects the role. Without these, the socket
    // calls below would silently operate on an empty IP / uninitialized port.
    std::vector<std::string> missing_vars;
    if (is_client_ == -1) {
        missing_vars.emplace_back("ILLIXR_IS_CLIENT (set to 1 for the client process, 0 for the server process)");
    }
    if (server_ip_.empty()) {
        missing_vars.emplace_back("ILLIXR_TCP_SERVER_IP");
    }
    if (server_port_ == -1) {
        missing_vars.emplace_back("ILLIXR_TCP_SERVER_PORT");
    }
    if (!missing_vars.empty()) {
        std::string joined;
        for (size_t i = 0; i < missing_vars.size(); i++) {
            joined += (i == 0 ? "" : ", ") + missing_vars[i];
        }
        throw std::runtime_error("[tcp_network_backend] Missing required environment variable(s): " + joined +
                                  ". Set them in the env_vars section of your yaml config (see "
                                  "plugins/tcp_network_backend/README.md).");
    }

    if (is_client_) {
        client          = true;
        network_thread_ = std::thread([this]() {
            start_client();
        });

        // wait till we are connected
        while (!ready_) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    } else {
        client          = false;
        network_thread_ = std::thread([this]() {
            start_server();
        });

        while (!ready_) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
}

void tcp_network_backend::start_client() {
    auto* socket = new network::TCPSocket();
    if (switchboard_->get_env_char("ILLIXR_TCP_CLIENT_IP") && switchboard_->get_env_char("ILLIXR_TCP_CLIENT_PORT")) {
        socket->socket_bind(client_ip_, client_port_);
    }
    socket->socket_set_reuseaddr();
    socket->enable_no_delay();
    peer_socket_ = socket;

    std::cout << "Connecting to " + server_ip_ + " at port " + std::to_string(server_port_) << std::endl;
    socket->socket_connect(server_ip_, server_port_);
    std::cout << "Connected to server" << std::endl;

    ready_ = true;
    read_loop(socket);
}

void tcp_network_backend::start_server() {
    network::TCPSocket server_socket;
    server_socket.socket_set_reuseaddr();
    server_socket.socket_bind(server_ip_, server_port_);
    server_socket.enable_no_delay();
    server_socket.socket_listen();

    auto* client_socket = new network::TCPSocket(server_socket.socket_accept());
    std::cout << "Accepted connection from client: " << client_socket->peer_address() << std::endl;
    peer_socket_ = client_socket;
    ready_       = true;
    read_loop(client_socket);
}

void tcp_network_backend::read_loop(network::TCPSocket* socket) {
    std::string                          buffer;
    std::chrono::steady_clock::time_point last_stats_sample{};
    while (running_) {
        // read from socket
        // packet are in the format
        // total_length:4bytes|topic_name_length:4bytes|topic_name|message
        std::string packet;
        try {
            packet = socket->read_data();
        } catch (const std::exception& e) {
            // running_ is false when this is a deliberate shutdown (stop() calls socket_shutdown()
            // to unblock this read); only treat it as an error when the disconnect was unexpected.
            if (running_) {
                spdlog::get("illixr")->error("[tcp_network_backend] Network read failed, stopping: {}", e.what());
            }
            return;
        }
        buffer += packet;

        // check if we have a complete packet
        while (buffer.size() >= 8) {
            uint32_t total_length = *reinterpret_cast<uint32_t*>(buffer.data());
            if (buffer.size() >= total_length) {
                uint32_t          topic_name_length = *reinterpret_cast<uint32_t*>(buffer.data() + 4);
                std::string       topic_name(buffer.data() + 8, topic_name_length);
                std::vector<char> message(buffer.begin() + 8 + topic_name_length, buffer.begin() + total_length);
                topic_receive(topic_name, message);
                record_logger_->log(record{_tcp_frame_header,
                                           {
                                               {now_ns()},
                                               {std::string{"rx"}},
                                               {topic_name},
                                               {static_cast<std::size_t>(total_length)},
                                           }});
                buffer.erase(buffer.begin(), buffer.begin() + total_length);
            } else {
                break;
            }
        }

        // Sample TCP_INFO at most once/second -- cheap kernel getsockopt call, no need for a
        // dedicated timer thread since this loop already spins continuously on read().
        auto now = std::chrono::steady_clock::now();
        if (now - last_stats_sample >= std::chrono::seconds(1)) {
            auto stats = socket->get_tcp_info();
            record_logger_->log(record{_tcp_socket_stats_header,
                                       {
                                           {now_ns()},
                                           {static_cast<std::size_t>(stats.rtt_us)},
                                           {static_cast<std::size_t>(stats.rttvar_us)},
                                           {static_cast<std::size_t>(stats.retransmits)},
                                           {static_cast<std::size_t>(stats.total_retrans)},
                                           {static_cast<std::size_t>(stats.snd_cwnd)},
                                           {static_cast<std::size_t>(stats.unacked)},
                                       }});
            last_stats_sample = now;
        }
    }
}

void tcp_network_backend::topic_create(std::string topic_name, network::topic_config& config) {
    networked_topics_.push_back(topic_name);
    networked_topics_configs_[topic_name] = config;
    std::string serializaiton;
    if (config.serialization_method == network::topic_config::SerializationMethod::BOOST) {
        serializaiton = "BOOST";
    } else {
        serializaiton = "PROTOBUF";
    }
    std::string message = "create_topic" + topic_name + delimiter_ + serializaiton;
    send_to_peer("illixr_control", std::move(message));
}

bool tcp_network_backend::is_topic_networked(std::string topic_name) {
    return std::find(networked_topics_.begin(), networked_topics_.end(), topic_name) != networked_topics_.end();
}

void tcp_network_backend::topic_send(std::string topic_name, std::string&& message) {
    if (is_topic_networked(topic_name) == false) {
        std::cout << "Topic not networked" << std::endl;
        return;
    }

    send_to_peer(topic_name, std::move(message));
}

// Helper function to queue a received message into the corresponding topic
void tcp_network_backend::topic_receive(const std::string& topic_name, std::vector<char>& message) {
    if (topic_name == "illixr_control") {
        std::string message_str(message.begin(), message.end());
        // check if message starts with "create_topic"
        if (message_str.find("create_topic") == 0) {
            size_t d_pos = message_str.find(delimiter_);
            assert(d_pos != std::string::npos);
            std::string l_topic_name  = message_str.substr(12, d_pos - 12);
            std::string serialization = message_str.substr(d_pos + 1);
            networked_topics_.push_back(l_topic_name);
            network::topic_config config;
            if (serialization == "BOOST") {
                config.serialization_method = network::topic_config::SerializationMethod::BOOST;
            } else {
                config.serialization_method = network::topic_config::SerializationMethod::PROTOBUF;
            }
            networked_topics_configs_[l_topic_name] = config;
            std::cout << "Received create_topic for " << l_topic_name << std::endl;
        }
        return;
    }

    if (!switchboard_->topic_exists(topic_name)) {
        return;
    }

    switchboard_->get_topic(topic_name).deserialize_and_put(message, networked_topics_configs_[topic_name]);
}

void tcp_network_backend::stop() {
    running_ = false;
    // Unblock the network thread's pending read so it can observe running_ == false and return,
    // before we join it. Without this, the thread could still be inside read_data() on
    // peer_socket_ when we delete it below, causing a use-after-free.
    if (peer_socket_) {
        peer_socket_->socket_shutdown();
    }
    if (network_thread_.joinable()) {
        network_thread_.join();
    }
    delete peer_socket_;
    peer_socket_ = nullptr;
}

void tcp_network_backend::send_to_peer(const std::string& topic_name, std::string&& message) {
    // packet are in the format
    // total_length:4bytes|topic_name_length:4bytes|topic_name|message
    uint32_t    total_length = 8 + topic_name.size() + message.size();
    std::string packet;
    packet.append(reinterpret_cast<char*>(&total_length), 4);
    uint32_t topic_name_length = topic_name.size();
    packet.append(reinterpret_cast<char*>(&topic_name_length), 4);
    packet.append(topic_name);
    packet.append(message.begin(), message.end());
    peer_socket_->write_data(packet);
    record_logger_->log(record{_tcp_frame_header,
                               {
                                   {now_ns()},
                                   {std::string{"tx"}},
                                   {topic_name},
                                   {static_cast<std::size_t>(total_length)},
                               }});
}

extern "C" plugin* this_plugin_factory(phonebook* pb) {
    auto* obj = new tcp_network_backend("tcp_network_backend", pb);
    // runtime_impl::load_so takes ownership of `obj` through its own shared_ptr (constructed from
    // the raw pointer this factory returns). Registering a second, independently-owned shared_ptr
    // to the same object here would double-delete it on shutdown. Use a no-op deleter so the
    // registry entry shares identity with `obj` without competing for ownership of it.
    pb->register_impl<network::network_backend>(
        std::shared_ptr<network::network_backend>(static_cast<network::network_backend*>(obj), [](network::network_backend*) {
        }));
    return obj;
}
