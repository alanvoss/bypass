defmodule Bypass.Plug do
  def init([pid]), do: pid

  def call(conn, pid) do
    Bypass.Instance.call(pid, {:plug, conn})
  end

  defp retain_current_plug(pid), do: Bypass.Instance.cast(pid, {:retain_plug_process, self()})
  defp put_result(pid, result), do: Bypass.Instance.call(pid, {:put_expect_result, result})
end
