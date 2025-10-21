from opensearchpy import OpenSearch
import json 

client = OpenSearch(
    hosts=[{"host": "sf-restaurant-opensearch.us-east-1.opensearch.localhost.localstack.cloud", "port": 4566}],
    use_ssl=False,  # LocalStack uses HTTP
    verify_certs=False,
)

# Load restaurant data from JSON file
with open('restaurants.json', 'r') as f:
    documents = json.load(f)

bulk_data = []
for doc in documents:
    bulk_data.append({'index': {'_index': 'restaurants', '_id': doc['id']}})
    bulk_data.append(doc)

response = client.bulk(body=bulk_data)

search_result = client.search(
    index="restaurants",
    body={"query": {"match": {"tags.cuisine": "pizza"}}}
)
print("Pizza restaurants:", search_result)