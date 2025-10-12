from urllib import response
import uvicorn
from fastapi import FastAPI, WebSocket

app = FastAPI()

@app.get("/health")
async def health():
    return response.Response(content="OK", status_code=200)


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    while True:
        data = await websocket.receive_text()
        await websocket.send_text(f"Message text was: {data}")

if __name__ == "__main__":
    uvicorn.run(
        "app:app",  # Replace 'app:app' with the actual module and app instance name
        host="0.0.0.0",
        workers=2,
        port=8000,
        reload=True,  # Enable auto-reload for development
        log_level="info",  # Set log level
    )