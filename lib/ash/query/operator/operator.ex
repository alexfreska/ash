defmodule Ash.Query.Operator do
  @moduledoc """
  An operator is a predicate with a `left` and a `right`

  For more information on being a predicate, see `Ash.Filter.Predicate`. Most of the complexities
  are there. An operator must meet both behaviours.
  """

  @doc """
  Create a new predicate. There are various return types possible:

    * `{:ok, left, right}` - Return the left/right values of the operator
    * `{:ok, operator}` - Return the operator itself, this or the one above are acceptable
    * `{:known, boolean}` - If the value is already known, e.g `1 == 1`
    * `{:error, error}` - If there was an error creating the operator
  """
  @callback new(term, term) ::
              {:ok, term, term} | {:ok, term} | {:known, boolean} | {:error, Ash.error()}

  @doc """
  The implementation of the inspect protocol.

  If not defined, it will be inferred
  """
  @callback to_string(struct, Inspect.Opts.t()) :: term

  @doc "Create a new operator. Pass the module and the left and right values"
  def new(mod, left, right) do
    case mod.new(left, right) do
      {:ok, left, right} -> {:ok, struct(mod, left: left, right: right)}
      {:ok, %_{} = op} -> {:ok, op}
      {:known, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  defmacro __using__(opts) do
    unless opts[:operator] do
      raise "Operator is required!"
    end

    quote do
      defstruct [
        :left,
        :right,
        operator: unquote(opts[:operator]),
        embedded?: false,
        __operator__?: true,
        __predicate__?: unquote(opts[:predicate?] || false)
      ]

      if unquote(opts[:predicate?]) do
        @behaviour Ash.Filter.Predicate
      end

      alias Ash.Query.Ref

      def operator, do: unquote(opts[:operator])
      def name, do: unquote(opts[:name] || opts[:operator])

      if unquote(opts[:predicate?]) do
        @dialyzer {:nowarn_function, match?: 1}
        def match?(struct) do
          evaluate(struct) not in [nil, false]
        end
      end

      def types do
        unquote(opts[:types] || [:any_same_or_ref])
      end

      import Inspect.Algebra

      def to_string(%{left: left, right: right, operator: operator}, opts) do
        concat([
          to_doc(left, opts),
          " ",
          to_string(operator),
          " ",
          to_doc(right, opts)
        ])
      end

      defoverridable to_string: 2

      defimpl Inspect do
        def inspect(%mod{} = op, opts) do
          mod.to_string(op, opts)
        end
      end
    end
  end
end
