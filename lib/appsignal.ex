defmodule Appsignal do
  @moduledoc """
  AppSignal for Elixir. Follow the [installation guide](https://docs.appsignal.com/elixir/installation.html) to install AppSignal into your Elixir app.

  This module contains the main AppSignal OTP application, as well as
  a few helper functions for sending metrics to AppSignal.

  These metrics do not rely on an active transaction being
  present. For transaction related-functions, see the
  [Appsignal.Transaction](Appsignal.Transaction.html) module.

  """

  use Application

  alias Appsignal.{Backtrace, Config, Error}

  require Logger

  @transaction Application.get_env(
                 :appsignal,
                 :appsignal_transaction,
                 Appsignal.Transaction
               )

  if System.otp_release() >= "21" do
    @report_handler Appsignal.LoggerHandler
  else
    @report_handler Appsignal.ErrorLoggerHandler
  end

  @doc """
  Application callback function
  """
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    initialize()
    add_report_handler()

    if phoenix?(), do: Appsignal.Phoenix.EventHandler.attach()

    children = [
      worker(Appsignal.Transaction.Receiver, [], restart: :permanent),
      worker(Appsignal.Transaction.ETS, [], restart: :permanent),
      worker(Appsignal.Probes, [])
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Appsignal.Supervisor)

    # Add our default system probes. It's important that this is called after
    # the Suportvisor has started. Otherwise the GenServer cannot register the
    # probe.
    add_default_probes()

    result
  end

  def plug? do
    Code.ensure_loaded?(Plug)
  end

  def phoenix? do
    Code.ensure_loaded?(Phoenix)
  end

  def live_view? do
    phoenix?() && Code.ensure_loaded?(Phoenix.LiveView)
  end

  @doc """
  Application callback function
  """
  def stop(_state) do
    Logger.debug("AppSignal stopping.")
  end

  def config_change(_changed, _new, _removed) do
    # Spawn a separate process that reloads the configuration. AppSignal can't
    # reload it in the same process because the GenServer would continue
    # calling itself once it reached `Application.put_env` in
    # `Appsignal.Config`.
    spawn(fn ->
      :ok = Appsignal.Nif.stop()
      :ok = initialize()
    end)
  end

  @doc false
  def initialize do
    case {Config.initialize(), Config.configured_as_active?()} do
      {_, false} ->
        Logger.info("AppSignal disabled.")

      {:ok, true} ->
        Logger.debug("AppSignal starting.")
        Config.write_to_environment()
        Appsignal.Nif.start()

        if Appsignal.Nif.loaded?() do
          Logger.debug("AppSignal started.")
        else
          Logger.error(
            "Failed to start AppSignal. Please run the diagnose task " <>
              "(https://docs.appsignal.com/elixir/command-line/diagnose.html) " <>
              "to debug your installation."
          )
        end

      {{:error, :invalid_config}, true} ->
        Logger.warn(
          "Warning: No valid AppSignal configuration found, continuing with " <>
            "AppSignal metrics disabled."
        )
    end
  end

  @doc false
  def add_report_handler, do: @report_handler.add()

  @doc false
  def remove_report_handler, do: @report_handler.remove()

  @doc false
  def add_default_probes do
    Appsignal.Probes.register(:erlang, &Appsignal.Probes.ErlangProbe.call/0)
  end

  @doc """
  Set a gauge for a measurement of some metric.
  """
  @spec set_gauge(String.t(), float | integer, map) :: :ok
  def set_gauge(key, value, tags \\ %{})

  def set_gauge(key, value, tags) when is_integer(value) do
    set_gauge(key, value + 0.0, tags)
  end

  def set_gauge(key, value, %{} = tags) when is_float(value) do
    encoded_tags = Appsignal.Utils.DataEncoder.encode(tags)
    :ok = Appsignal.Nif.set_gauge(key, value, encoded_tags)
  end

  @doc """
  Increment a counter of some metric.
  """
  @spec increment_counter(String.t(), number, map) :: :ok
  def increment_counter(key, count \\ 1, tags \\ %{})

  def increment_counter(key, count, %{} = tags) when is_number(count) do
    encoded_tags = Appsignal.Utils.DataEncoder.encode(tags)
    :ok = Appsignal.Nif.increment_counter(key, count + 0.0, encoded_tags)
  end

  @doc """
  Add a value to a distribution

  Use this to collect multiple data points that will be merged into a
  graph.
  """
  @spec add_distribution_value(String.t(), float | integer, map) :: :ok
  def add_distribution_value(key, value, tags \\ %{})

  def add_distribution_value(key, value, tags) when is_integer(value) do
    add_distribution_value(key, value + 0.0, tags)
  end

  def add_distribution_value(key, value, %{} = tags) when is_float(value) do
    encoded_tags = Appsignal.Utils.DataEncoder.encode(tags)
    :ok = Appsignal.Nif.add_distribution_value(key, value, encoded_tags)
  end

  @doc """
  Send an error to AppSignal

  When there is no current transaction, this call starts one.

  ## Examples
      Appsignal.send_error(%RuntimeError{})
      Appsignal.send_error(%RuntimeError{}, "", System.stacktrace())
      Appsignal.send_error(%RuntimeError{}, "", [], %{foo: "bar"})
      Appsignal.send_error(%RuntimeError{}, "", [], %{}, %Plug.Conn{})
      Appsignal.send_error(%RuntimeError{}, "", [], %{}, nil, fn(transaction) ->
        Appsignal.Transaction.set_sample_data(transaction, "key", %{foo: "bar"})
      end)
  """
  def send_error(
        error,
        prefix \\ "",
        stack \\ nil,
        metadata \\ %{},
        conn \\ nil,
        fun \\ fn t -> t end,
        namespace \\ :http_request
      ) do
    stack =
      case stack do
        nil ->
          IO.warn(
            "Appsignal.send_error/1-7 without passing a stack trace is deprecated, and defaults to passing an empty stacktrace. Please explicitly pass a stack trace or an empty list."
          )

          []

        _ ->
          stack
      end

    transaction = @transaction.create("_" <> @transaction.generate_id(), namespace)

    fun.(transaction)
    {exception, stacktrace} = Error.normalize(error, stack)
    {name, message} = Error.metadata(exception)
    backtrace = Backtrace.from_stacktrace(stacktrace)

    Appsignal.ErrorHandler.submit_transaction(
      transaction,
      name,
      prefixed(prefix, message),
      backtrace,
      metadata,
      conn
    )
  end

  defp prefixed("", message), do: message
  defp prefixed(prefix, message) when is_binary(prefix), do: prefix <> ": " <> message
  defp prefixed(_, message), do: message
end
