import asyncio
import httpx
import json
import time
import subprocess
import sys
import os
from pathlib import Path

async def test_server():
    """Test the server by sending a message and checking response"""
    
    print("⏳ Waiting for server to initialize and load model...")
    await asyncio.sleep(10)
    
    # Test server availability
    for i in range(30):
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.get("http://localhost:8000")
                if response.status_code == 200:
                    print(f"  ✓ Server responded (attempt {i+1})")
                    break
        except Exception as e:
            print(f"  ⏳ Waiting for server... ({i+1}/30)")
        await asyncio.sleep(1)
    
    print("\n" + "="*60)
    print("🧪 STARTING MODEL TEST")
    print("="*60)
    
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            # Start session
            print("\n📝 Creating new session...")
            start_response = await client.post(
                "http://localhost:8000/api/chat/start",
                json={"metadata": {"test": True, "source": "github-actions"}}
            )
            session_data = start_response.json()
            session_id = session_data["session_id"]
            memory_loaded = session_data["memory_loaded"]
            print(f"  ✓ Session ID: {session_id}")
            print(f"  ✓ Memory loaded: {memory_loaded}")
            
            # Send test message
            test_message = "Hello, please introduce yourself briefly."  # Will be overridden by sed
            print(f"\n💬 Sending: \"{test_message}\"")
            
            response = await client.post(
                f"http://localhost:8000/api/chat/{session_id}",
                json={"message": test_message}
            )
            
            # Read streaming response
            print("\n🤖 Model response:")
            print("-"*50)
            
            full_response = ""
            async for line in response.aiter_lines():
                if line and line.startswith("data: "):
                    try:
                        data = json.loads(line[6:])
                        if "chunk" in data:
                            print(data["chunk"], end="", flush=True)
                            full_response += data["chunk"]
                        elif "done" in data:
                            print("\n" + "-"*50)
                            print(f"✅ Response complete! Length: {len(full_response)} chars")
                        elif "error" in data:
                            print(f"\n❌ Error: {data['error']}")
                    except json.JSONDecodeError:
                        continue
            
            # End session
            print("\n🔄 Ending session...")
            end_response = await client.post(f"http://localhost:8000/api/chat/{session_id}/end")
            print("  ✓ Session saved to memory")
            
            # Check memory was updated
            memory_response = await client.get("http://localhost:8000/api/memory")
            memory_data = memory_response.json()
            memory_preview = memory_data.get("memory", "")[-500:]  # Last 500 chars
            print("\n📚 Latest memory preview:")
            print("-"*50)
            print(memory_preview)
            print("-"*50)
            
            return True, full_response
            
    except Exception as e:
        print(f"\n❌ Test failed: {type(e).__name__}: {e}")
        return False, str(e)

async def main():
    print("="*60)
    print("🚀 LOCAL MODEL DEPLOYMENT TEST")
    print("="*60)
    
    # Verify model exists
    model_path = Path("models/model.model")
    if not model_path.exists():
        print(f"❌ ERROR: Model not found at {model_path.absolute()}")
        print(f"Current directory: {os.getcwd()}")
        print(f"Files in current directory: {os.listdir('.')}")
        if os.path.exists("models"):
            print(f"Files in models directory: {os.listdir('models')}")
        return False
    
    model_size = model_path.stat().st_size / (1024 * 1024)
    print(f"✅ Model found: {model_size:.1f} MB")
    
    # Start the server
    print("\n🚀 Starting FastAPI server...")
    server_process = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--log-level", "info"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=os.getcwd(),
        text=True
    )
    
    try:
        # Give server time to start
        await asyncio.sleep(5)
        
        # Run tests
        success, response = await test_server()
        
        if success:
            print("\n" + "="*60)
            print("✅✅✅ ALL TESTS PASSED! ✅✅✅")
            print("="*60)
            print("\n🎯 Next steps:")
            print("   1. Use ngrok for temporary access:")
            print("      ngrok http 8000")
            print("   2. Deploy to a cloud VM for permanent hosting")
            return True
        else:
            print("\n" + "="*60)
            print("❌❌❌ TESTS FAILED ❌❌❌")
            print("="*60)
            return False
            
    finally:
        # Cleanup
        print("\n🧹 Cleaning up...")
        server_process.terminate()
        try:
            server_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server_process.kill()
        
        # Show server logs if there was an error
        stdout, stderr = server_process.communicate()
        if stderr:
            print("\n📋 Server logs (stderr):")
            print(stderr[-2000:] if len(stderr) > 2000 else stderr)
        if stdout:
            print("\n📋 Server logs (stdout):")
            print(stdout[-1000:] if len(stdout) > 1000 else stdout)

if __name__ == "__main__":
    success = asyncio.run(main())
    sys.exit(0 if success else 1)