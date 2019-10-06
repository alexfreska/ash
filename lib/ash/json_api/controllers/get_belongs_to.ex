defmodule Ash.JsonApi.Controllers.GetBelongsTo do
  def init(options) do
    # initialize options
    options
  end

  def call(%{path_params: %{"id" => id}} = conn, options) do
    resource = options[:resource]
    relationship = options[:relationship]

    request = Ash.JsonApi.Request.from(conn, relationship.destination, :get_belongs_to)

    case Ash.Repo.get(resource, id) do
      nil ->
        conn
        # |> put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(404, "uh oh")

      found ->
        related =
          found
          |> Ecto.assoc(relationship.name)
          |> Ash.Repo.one()

        serialized = Ash.JsonApi.Serializer.serialize_one(request, related)

        conn
        |> Plug.Conn.put_resp_content_type("application/vnd.api+json")
        |> Plug.Conn.send_resp(200, serialized)
    end
    |> Plug.Conn.halt()
  end
end