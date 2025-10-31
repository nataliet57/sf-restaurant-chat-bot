import json
import boto3
import urllib3
from opensearchpy import OpenSearch, RequestsHttpConnection
import os
import logging

# Set up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    Loads restaurant data from S3 JSON file into OpenSearch index
    Triggered by S3 putObject events
    """
    try:
        # Get S3 bucket and key from event
        s3 = boto3.client('s3')
        record = event['Records'][0]
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']
        
        logger.info(f"Processing file: s3://{bucket}/{key}")
        
        # 1. Download and parse JSON from S3
        response = s3.get_object(Bucket=bucket, Key=key)
        data = json.loads(response['Body'].read().decode('utf-8'))
        elements = data.get('elements', [])
        logger.info(f"Found {len(elements)} elements in JSON")
        
        # 2. Connect to OpenSearch
        opensearch_host = os.environ['OPENSEARCH_HOST']
        if opensearch_host.startswith('[') and opensearch_host.endswith(']'):
            opensearch_host = opensearch_host[1:-1]
        opensearch_url = f"https://{opensearch_host}"
        opensearch = OpenSearch(
            hosts=[opensearch_url],
            http_compress=True,
            verify_certs=False,
            connection_class=RequestsHttpConnection,
            timeout=30
        )
        
        # 3. Create index if it doesn't exist
        index_name = "restaurants"
        if not opensearch.indices.exists(index=index_name):
            index_body = {
                "settings": {
                    "number_of_shards": 1,
                    "number_of_replicas": 0,
                    "index": {
                        "refresh_interval": "1s"
                    }
                },
                "mappings": {
                    "properties": {
                        "id": {"type": "keyword"},
                        "name": {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
                        "amenity": {"type": "keyword"},
                        "cuisine": {"type": "keyword"},
                        "address": {
                            "type": "object",
                            "properties": {
                                "street": {"type": "text"},
                                "city": {"type": "keyword"},
                                "postcode": {"type": "keyword"}
                            }
                        },
                        "location": {"type": "geo_point"},
                        "timestamp": {"type": "date"},
                        "type": {"type": "keyword"}  # node, way, relation
                    }
                }
            }
            opensearch.indices.create(index=index_name, body=index_body)
            logger.info(f"Created index: {index_name}")
        
        # 4. Transform and index data
        successful_indexes = 0
        bulk_data = []
        
        for element in elements:
            doc = transform_element(element)
            if doc and doc.get('location'):
                # Add to bulk operations
                bulk_data.append({'index': {'_index': index_name, '_id': str(doc['id'])}})
                bulk_data.append(doc)
                
                # Execute bulk in batches of 100
                if len(bulk_data) >= 200:
                    response = opensearch.bulk(body=bulk_data, refresh=False)
                    successful_indexes += process_bulk_response(response)
                    bulk_data = []
        
        # Process remaining documents
        if bulk_data:
            response = opensearch.bulk(body=bulk_data, refresh=True)
            successful_indexes += process_bulk_response(response)
        
        logger.info(f"Successfully indexed {successful_indexes} documents")
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': f'Successfully processed {successful_indexes} restaurants',
                'indexed_count': successful_indexes,
                'total_elements': len(elements)
            })
        }
        
    except Exception as e:
        logger.error(f"Error processing S3 event: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def transform_element(element):
    """Transform OpenStreetMap element to our restaurant schema"""
    try:
        tags = element.get('tags', {})
        
        # Only process elements with restaurant-related amenities
        amenity = tags.get('amenity', '')
        if amenity not in ['restaurant', 'cafe', 'fast_food', 'bar', 'pub']:
            return None
        
        # Extract location
        lat = element.get('lat') or (element.get('center', {}).get('lat'))
        lon = element.get('lon') or (element.get('center', {}).get('lon'))
        
        if not lat or not lon:
            return None
        
        doc = {
            'id': element.get('id'),
            'name': tags.get('name', 'Unknown'),
            'amenity': amenity,
            'cuisine': tags.get('cuisine', '').split(';') if tags.get('cuisine') else [],
            'type': element.get('type'),
            'location': {
                'lat': float(lat),
                'lon': float(lon)
            },
            'address': {
                'street': tags.get('addr:street'),
                'city': tags.get('addr:city', 'San Francisco'),
                'postcode': tags.get('addr:postcode')
            },
            'timestamp': element.get('timestamp')
        }
        
        return doc
        
    except Exception as e:
        logger.warning(f"Error transforming element {element.get('id')}: {str(e)}")
        return None

def process_bulk_response(response):
    """Process bulk API response and count successes"""
    if response.get('errors'):
        for item in response['items']:
            if 'error' in item.get('index', {}):
                logger.error(f"Index error: {item['index']['error']}")
    return len(response['items'])