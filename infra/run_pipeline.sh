#!/bin/bash

echo "Step 1: Executing OSM Query Lambda..."
awslocal lambda invoke --function-name query-openstreetmap-lambda response1.json
echo "Response: $(cat response1.json)"
echo ""

echo "Step 2: Checking if file was created in S3..."
awslocal s3 ls s3://sf-restaurant-opensearch-artifacts-000000000000/
echo ""

echo "Step 3: The S3 event should automatically trigger the second Lambda"
echo "Check CloudWatch logs for s3-to-opensearch-loader Lambda"
echo ""

echo "Step 4: Verify data in OpenSearch..."
curl -s "https://sf-restaurant-opensearch.us-east-1.opensearch.localhost.localstack.cloud:4566/restaurants/_search?pretty" | head -20