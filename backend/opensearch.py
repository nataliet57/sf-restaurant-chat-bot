from opensearchpy import OpenSearch
import json 

client = OpenSearch(
    hosts=[{"host": "sf-restaurant-opensearch.us-east-1.opensearch.localhost.localstack.cloud", "port": 4566}],
    use_ssl=False,  # LocalStack uses HTTP
    verify_certs=False,
)

def search_restaurants(cuisine: str, postal_code: str | None = None, index: str = "restaurants"):
    """Search restaurants by cuisine and optional postal code.

    Args:
        cuisine: cuisine string to match (e.g. 'pizza').
        postal_code: optional postal code to filter by.
        index: OpenSearch index name.

    Returns:
        The raw search response from OpenSearch client.search().
    """
    # Build a boolean query that must match cuisine and optionally postal code
    must_clauses = [
        {"match": {"tags.cuisine": cuisine}}
    ]

    if postal_code:
        # Assuming postal code is stored at top-level field 'postal_code' in documents
        must_clauses.append({"term": {"postal_code": postal_code}})

    body = {"query": {"bool": {"must": must_clauses}}}

    return client.search(index=index, body=body)


if __name__ == "__main__":
    # When executed directly, perform the bulk indexing (once) and run an example search.
    # Load restaurant data from JSON file
    with open('restaurants.json', 'r') as f:
        documents = json.load(f)

    bulk_data = []
    for doc in documents:
        bulk_data.append({'index': {'_index': 'restaurants', '_id': doc['id']}})
        bulk_data.append(doc)

    # Bulk index documents (idempotent for this demo)
    response = client.bulk(body=bulk_data)
    print('Bulk index response:', response.get('errors', False))

    # Example: search for pizza restaurants in postal code '94110'
    search_result = search_restaurants('pizza', postal_code='94110')
    print('Search result:', search_result)