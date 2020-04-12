defmodule Ash.Actions.Create do
  alias Ash.Engine
  alias Ash.Actions.{Attributes, Relationships, SideLoad}
  require Logger

  @spec run(Ash.api(), Ash.resource(), Ash.action(), Ash.params()) ::
          {:ok, Ash.record()} | {:error, Ecto.Changeset.t()} | {:error, Ash.error()}
  def run(api, resource, action, params) do
    transaction_result =
      Ash.DataLayer.transact(resource, fn ->
        do_run(api, resource, action, params)
      end)

    case transaction_result do
      {:ok, value} -> value
      {:error, error} -> {:error, error}
    end
  end

  defp do_run(api, resource, action, params) do
    attributes = Keyword.get(params, :attributes, %{})
    side_loads = Keyword.get(params, :side_load, [])
    side_load_filter = Keyword.get(params, :side_load_filter)
    relationships = Keyword.get(params, :relationships, %{})

    with {:ok, relationships} <-
           Relationships.validate_not_changing_relationship_and_source_field(
             relationships,
             attributes,
             resource
           ),
         {:ok, attributes, relationships} <-
           Relationships.field_changes_into_relationship_changes(
             relationships,
             attributes,
             resource
           ),
         params <- Keyword.merge(params, attributes: attributes, relationships: relationships),
         %{valid?: true} = changeset <- changeset(api, resource, params),
         {:ok, side_load_requests} <-
           SideLoad.requests(api, resource, side_loads, side_load_filter, :create),
         %{data: %{data: %{data: %^resource{} = created}}} = state <-
           do_authorized(changeset, params, action, resource, api, side_load_requests) do
      {:ok, SideLoad.attach_side_loads(created, state)}
    else
      %Ecto.Changeset{} = changeset ->
        {:error, changeset}

      %{errors: errors} when errors != %{} ->
        if params[:authorization][:log_final_report?] do
          case errors do
            %{__engine__: errors} ->
              for %Ash.Error.Forbidden{} = forbidden <- List.wrap(errors) do
                Logger.info(Ash.Error.Forbidden.report_text(forbidden))
              end

            _ ->
              :ok
          end
        end

        {:error, errors}

      {:error, error} ->
        if params[:authorization][:log_final_report?] do
          for %Ash.Error.Forbidden{} = forbidden <- List.wrap(error) do
            Logger.info(Ash.Error.Forbidden.report_text(forbidden))
          end
        end

        {:error, error}
    end
  end

  def changeset(api, resource, params) do
    attributes = Keyword.get(params, :attributes, %{})
    relationships = Keyword.get(params, :relationships, %{})

    resource
    |> prepare_create_attributes(attributes)
    |> Relationships.handle_relationship_changes(api, relationships, :create)
  end

  defp do_authorized(changeset, params, action, resource, api, side_load_requests) do
    relationships = Keyword.get(params, :relationships, %{})

    create_request =
      Ash.Engine.Request.new(
        api: api,
        rules: action.rules,
        resource: resource,
        changeset:
          Relationships.changeset(
            changeset,
            api,
            relationships
          ),
        action_type: action.type,
        strict_access?: false,
        data:
          Ash.Engine.Request.UnresolvedField.data(
            [[:data, :changeset]],
            fn %{data: %{changeset: changeset}} ->
              resource
              |> Ash.DataLayer.create(changeset)
              |> case do
                {:ok, result} ->
                  changeset
                  |> Map.get(:__after_changes__, [])
                  |> Enum.reduce_while({:ok, result}, fn func, {:ok, result} ->
                    case func.(changeset, result) do
                      {:ok, result} -> {:cont, {:ok, result}}
                      {:error, error} -> {:halt, {:error, error}}
                    end
                  end)

                {:error, error} ->
                  {:error, error}
              end
            end
          ),
        resolve_when_fetch_only?: true,
        path: [:data],
        name: "#{action.type} - `#{action.name}`"
      )

    attribute_requests = Attributes.attribute_change_requests(changeset, api, resource, action)

    relationship_read_requests = Map.get(changeset, :__requests__, [])

    relationship_change_requests =
      Relationships.relationship_change_requests(
        changeset,
        api,
        resource,
        action,
        relationships
      )

    if params[:authorization] do
      Engine.run(
        [create_request | attribute_requests] ++
          relationship_read_requests ++ relationship_change_requests ++ side_load_requests,
        api,
        user: params[:authorization][:user],
        log_final_report?: params[:authorization][:log_final_report?] || false
      )
    else
      Engine.run(
        [create_request | attribute_requests] ++
          relationship_read_requests ++ relationship_change_requests ++ side_load_requests,
        api,
        fetch_only?: true
      )
    end
  end

  defp prepare_create_attributes(resource, attributes) do
    allowed_keys =
      resource
      |> Ash.attributes()
      |> Enum.map(& &1.name)

    attributes_with_defaults =
      resource
      |> Ash.attributes()
      |> Enum.filter(&(not is_nil(&1.default)))
      |> Enum.reduce(attributes, fn attr, attributes ->
        if has_attr?(attributes, attr.name) do
          attributes
        else
          Map.put(attributes, attr.name, default(attr))
        end
      end)

    changeset =
      resource
      |> struct()
      |> Ecto.Changeset.cast(attributes_with_defaults, allowed_keys)
      |> Map.put(:action, :create)
      |> Map.put(:__ash_relationships__, %{})

    resource
    |> Ash.attributes()
    |> Enum.reject(&Map.get(&1, :allow_nil?))
    |> Enum.reduce(changeset, fn attr, changeset ->
      case Ecto.Changeset.get_field(changeset, attr.name) do
        nil -> Ecto.Changeset.add_error(changeset, attr.name, "must not be nil")
        _value -> changeset
      end
    end)
  end

  defp default(%{default: {:constant, value}}), do: value
  defp default(%{default: {mod, func}}), do: apply(mod, func, [])
  defp default(%{default: function}), do: function.()

  defp has_attr?(map, name) do
    Map.has_key?(map, name) || Map.has_key?(map, to_string(name))
  end
end
