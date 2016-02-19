defmodule Pigeon.APNSWorker do
  use GenServer
  require Logger

  def start_link(name, mode, cert, key) do
    Logger.debug("Starting worker #{name}\n\t mode: #{mode}, cert: #{cert}, key: #{key}")
    GenServer.start_link(__MODULE__, {:ok, mode, cert, key}, name: name)
  end

  def stop() do
    :gen_server.cast(self, :stop)
  end

  def push_uri(:dev), do: 'api.development.push.apple.com'
  def push_uri(:prod), do: 'api.push.apple.com'

  defp new_connection(mode, cert, key) do
    options = [{:certfile, cert},
               {:keyfile, key},
               {:password, ''},
               {:packet, 0},
               {:reuseaddr, true},
               {:active, :once},
               :binary]
    :http2_client.start_link(:https, push_uri(mode), options)
  end

  defp wait_for_response(socket, stream_id, receiver_pid) do
    :timer.sleep(200)
    case :http2_client.get_response(socket, stream_id) do
      {:error, :stream_not_finished} -> wait_for_response(socket, stream_id, receiver_pid)
      {:ok, response} -> send receiver_pid, {:http2_response, response}
    end
  end

  defp push_message(socket, _mode, topic, device_token, payload) do
    req_headers = [
      {":method", "POST"},
      # {":scheme", "https"},
      {":path", "/3/device/#{device_token}"},
      # {"host", push_uri(mode)},
      {"apns-topic", topic},
      {"content-length", "#{byte_size(payload)}"}
    ]
    {:ok, stream_id} = :http2_client.send_request(socket, req_headers, payload)
    # Dirty hack: since chatterbox doesn't support sending messages on responses
    # yet I wrote a polling loop that will probe the status of the response and
    # send a message as soon as it is available.
    receiver_pid = self()
    spawn fn -> wait_for_response(socket, stream_id, receiver_pid) end
  end

  def init({:ok, mode, cert, key}) do
    IO.puts "Opening connection..."
    {:ok, socket} = new_connection(mode, cert, key)
    IO.inspect socket
    IO.puts "...open"
    state = %{
      apns_socket: socket,
      mode: mode,
      cert: cert,
      key: key
    }
    {:ok, state}
  end

  def handle_call({:start_connection, mode, cert, key}, _from, _state) do
    {:ok, socket} = new_connection(mode, cert, key)
    state = %{
      apns_socket: socket,
      mode: mode,
      cert: cert,
      key: key
    }
    {:noreply, state}
  end

  def handle_call({:push, :apns, notification}, _from, %{apns_socket: socket, mode: mode} = state) do
    %{device_token: device_token, topic: topic, payload: payload} = notification
    push_message(socket, mode, topic, device_token, payload)
    { :reply, :ok, state }
  end

  defp get_header_value([{name, value} | _], name), do: value
  defp get_header_value([_ | rst], name), do: get_header_value(rst, name)
  defp get_header_value([], _), do: nil

  def handle_info({:http2_response, {headers, body}}, state) do
    Logger.debug "Got APNS response data..."
    if get_header_value(headers, ":status") != "200" do
      reason = Poison.decode!(body)["reason"]
      case reason do
        "BadDeviceToken" -> nil # TODO: remove token
        "Shutdown" -> nil # TODO: start a new connection
        _ -> nil # TODO: log
      end
    end
    { :noreply, state }
  end

  @doc "Handle the server stop message"
  def handle_cast(:stop , state) do
    { :noreply, state }
  end
end
