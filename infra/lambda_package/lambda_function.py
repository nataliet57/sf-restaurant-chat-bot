import json
import boto3
import requests
import os

def lambda_handler(event, context):
    query = """
    [out:json][timeout:25];
    area["name"="San Francisco"]["boundary"="administrative"]->.searchArea;
    (
      node["amenity"~"restaurant|cafe|fast_food|bar|pub|ice_cream|food_court|takeaway"](area.searchArea);
      way["amenity"~"restaurant|cafe|fast_food|bar|pub|ice_cream|food_court|takeaway"](area.searchArea);
      relation["amenity"~"restaurant|cafe|fast_food|bar|pub|ice_cream|food_court|takeaway"](area.searchArea);
    );
    out center;
    """

    response = requests.post("https://overpass-api.de/api/interpreter", data={"data": query})
    data = response.json()

    s3 = boto3.client("s3")
    bucket_name = os.environ["S3_BUCKET"]
    key = "sf_restaurants.json"

    s3.put_object(
        Bucket=bucket_name,
        Key=key,
        Body=json.dumps(data),
        ContentType="application/json"
    )

    return {
        "statusCode": 200,
        "body": json.dumps({"message": f"Uploaded {len(data.get('elements', []))} entries to {bucket_name}/{key}"})
    }
