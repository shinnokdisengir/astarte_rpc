defmodule Astarte.RPC.AMQPServer do
  @moduledoc """
  Behaviour module to implement an AMQP server replying to Astarte
  RPC calls.

  ## Example

  Define a module implementing the `process_rpc` callback and using the
  `use` macro to implement your AMQP RPC Server

    defmodule MyRPCServer do
      use Astarte.RPC.AMQPServer, queue: "my_rpc_queue"
      alias Astarte.RPC.Protocol.MyModule, as: MyRPC

      def process_rpc(payload)
        with %MyRPC.Call{call: call_tuple} <- MyRPC.Call.decode(payload),
             {:my_rpc_call, %{MyRPC.MyRPCCall{arg: arg, other: other}} <- call_tuple do

          do_my_rpc_call(arg, other)
        else
          {:error, :invalid_call}
      end
    end

  It is also possible to pass `amqp_options` to the `use` macro
  """

  @doc """
  Invoked when an AMQP message is received in the configured queue.

  `payload` is the serialized RPC call.

  Returning `:ok` will ACK the message and send no reply to the client.

  Returning `{:ok, reply}` will ACK the message and try to send a reply
  to the client, if the necessary AMQP metadata is set.

  Returning `{:error, :retry}` will reject the message, re-enqueuing it for
  a later retry.

  Returning `{:error, reason}` will reject the message effectively dropping
  it.

  If an exception is thrown in this function, the message is rejected and
  not re-enqueued.
  """
  @callback process_rpc(payload :: binary) ::
    :ok |
    {:ok, reply :: term} |
    {:error, :retry} |
    {:error, reason :: term}

  defmacro __using__(opts) do
    target_module = __CALLER__.module

    queue = Keyword.fetch!(opts, :queue)
    amqp_options = Keyword.get(opts, :amqp_options, [])

    quote do
      require Logger
      use GenServer

      @behaviour Astarte.RPC.AMQPServer

      @connection_backoff 10000
      @queue unquote(queue)

      def start_link do
        GenServer.start_link(__MODULE__, [])
      end

      def init(_opts) do
        rabbitmq_connect(false)
      end

      defp rabbitmq_connect(retry \\ true) do
        with {:ok, conn} <- AMQP.Connection.open(unquote(amqp_options)),
             # Get notifications when the connection goes down
             Process.monitor(conn.pid),
             {:ok, chan} <- AMQP.Channel.open(conn),
             {:ok, _consumer_tag} <- AMQP.Basic.consume(chan, @queue) do

          {:ok, chan}

        else
          {:error, reason} ->
            Logger.warn("RabbitMQ Connection error: " <> inspect(reason))
            maybe_retry(retry)
          :error ->
            Logger.warn("Unknown RabbitMQ connection error")
            maybe_retry(retry)
        end
      end

      defp maybe_retry(retry) do
        if retry do
          :timer.sleep(@connection_backoff)
          rabbitmq_connect(retry)
        else
          {:ok, nil}
        end
      end

      # Server callbacks

      # Confirmation sent by the broker after registering this process as a consumer
      def handle_info({:basic_consume_ok, %{consumer_tag: _consumer_tag}}, chan) do
        {:noreply, chan}
      end

      # Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)
      def handle_info({:basic_cancel, %{consumer_tag: _consumer_tag}}, chan) do
        {:stop, :normal, chan}
      end

      # Confirmation sent by the broker to the consumer process after a Basic.cancel
      def handle_info({:basic_cancel_ok, %{consumer_tag: _consumer_tag}}, chan) do
        {:noreply, chan}
      end

      def handle_info({:basic_deliver, payload, meta}, chan) do
        # We process the message asynchronously
        spawn_link fn -> consume(chan, payload, meta) end
        {:noreply, chan}
      end

      # This callback should try to reconnect to the server
      def handle_info({:DOWN, _, :process, _pid, _reason}, _chan) do
        {:ok, new_chan} = rabbitmq_connect()
        {:noreply, new_chan}
      end

      defp consume(chan, payload, meta) do
        apply_process_rpc(payload)
        |> ack_or_reject(chan, meta.delivery_tag)
        |> maybe_reply(chan, meta.reply_to, meta.correlation_id)
      end


      defp apply_process_rpc(payload) do
        try do
          apply(unquote(target_module), :process_rpc, [payload])
        rescue
          e ->
            Logger.warn("Exception while handling message: #{inspect(e)}")
            {:error, :exception}
        end
      end


      defp ack_or_reject(result = :ok, chan, delivery_tag) do
        AMQP.Basic.ack(chan, delivery_tag)
        result
      end

      defp ack_or_reject(result = {:ok, reply}, chan, delivery_tag) do
        AMQP.Basic.ack(chan, delivery_tag)
        result
      end

      defp ack_or_reject(result = {:error, :retry}, chan, delivery_tag) do
        AMQP.Basic.reject(chan, delivery_tag, [requeue: true])
        Logger.warn("Temporary error, re-enqueing the message")
        result
      end

      defp ack_or_reject(result = {:error, reason}, chan, delivery_tag) do
        AMQP.Basic.reject(chan, delivery_tag, [requeue: false])
        Logger.warn("Message rejected with reason #{inspect(reason)}")
        result
      end


      defp maybe_reply({status, _reply}, _chan, :undefined, _correlation_id) do
        Logger.warn("Got a reply but no queue to write it to")
      end

      defp maybe_reply({:ok, reply}, chan, reply_to, correlation_id) do
        AMQP.Basic.publish(chan, "", reply_to, reply, [correlation_id: correlation_id])
      end

      defp maybe_reply({:error, reason}, chan, reply_to, correlation_id) when is_binary(reason) do
        AMQP.Basic.publish(chan, "", reply_to, reason, [correlation_id: correlation_id])
      end

      defp maybe_reply({:error, reason}, chan, reply_to, correlation_id) when is_atom(reason) do
        AMQP.Basic.publish(chan, "", reply_to, to_string(reason), [correlation_id: correlation_id])
      end

      defp maybe_reply(_result, _chan, _reply_to, _correlation_id) do
        :ok
      end

    end # quote
  end # defmacro

end