import asyncio
from typing import AsyncGenerator, List, Dict, Any
import logging
import sys
from pathlib import Path

# Try importing different backends
try:
    import llama_cpp
    HAS_LLAMA_CPP = True
except ImportError:
    HAS_LLAMA_CPP = False
    print("llama-cpp-python not found. Install with: pip install llama-cpp-python")

try:
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    HAS_TRANSFORMERS = True
except ImportError:
    HAS_TRANSFORMERS = False
    print("transformers not found. Install with: pip install transformers torch")

class ModelLoader:
    def __init__(self, model_path: str):
        self.model_path = Path(model_path)
        self.model = None
        self.tokenizer = None
        self.backend = None
        self.load_model()
    
    def load_model(self):
        """Load the model using available backend"""
        if not self.model_path.exists():
            raise FileNotFoundError(f"Model not found at {self.model_path}")
        
        # Try llama.cpp first (best for GGUF models)
        if HAS_LLAMA_CPP and str(self.model_path).endswith(('.gguf', '.bin')):
            print(f"Loading model with llama.cpp: {self.model_path}")
            try:
                self.model = llama_cpp.Llama(
                    model_path=str(self.model_path),
                    n_ctx=2048,  # Context window
                    n_threads=8,  # CPU threads
                    n_gpu_layers=-1,  # Use GPU if available (-1 = all)
                    verbose=False
                )
                self.backend = "llama.cpp"
                print("Model loaded successfully with llama.cpp")
                return
            except Exception as e:
                print(f"llama.cpp loading failed: {e}")
        
        # Fall back to transformers
        if HAS_TRANSFORMERS:
            print(f"Loading model with transformers: {self.model_path}")
            try:
                self.tokenizer = AutoTokenizer.from_pretrained(self.model_path.parent)
                self.model = AutoModelForCausalLM.from_pretrained(
                    self.model_path.parent,
                    torch_dtype=torch.float16 if torch.cuda.is_available() else torch.float32,
                    device_map="auto",
                    low_cpu_mem_usage=True
                )
                self.backend = "transformers"
                print("Model loaded successfully with transformers")
                return
            except Exception as e:
                print(f"Transformers loading failed: {e}")
        
        raise RuntimeError("No suitable backend found to load the model")
    
    def format_prompt(self, messages: List[Dict[str, str]], memory: str = "") -> str:
        """Format messages into a prompt string"""
        prompt = ""
        
        # Add memory if available
        if memory:
            prompt += f"<memory>\n{memory}\n</memory>\n\n"
        
        # Add conversation history
        for msg in messages:
            if msg["role"] == "user":
                prompt += f"User: {msg['content']}\n"
            else:
                prompt += f"Assistant: {msg['content']}\n"
        
        # Add the current prompt
        if not messages or messages[-1]["role"] != "user":
            prompt += "User: "
        
        prompt += "Assistant: "
        return prompt
    
    async def generate_stream(self, context: Dict[str, Any]) -> AsyncGenerator[str, None]:
        """Generate text from the model with streaming"""
        prompt = context.get("prompt", "")
        
        if self.backend == "llama.cpp":
            # Use llama.cpp streaming
            stream = self.model(
                prompt,
                max_tokens=2048,
                temperature=0.7,
                top_p=0.95,
                stop=["User:", "\nUser ", "Human:", "\nHuman "],
                echo=False,
                stream=True
            )
            
            for chunk in stream:
                yield chunk["choices"][0]["text"]
                await asyncio.sleep(0)  # Allow other tasks to run
        
        elif self.backend == "transformers":
            # Use transformers streaming
            inputs = self.tokenizer(prompt, return_tensors="pt")
            
            # Move to GPU if available
            if torch.cuda.is_available():
                inputs = {k: v.to("cuda") for k, v in inputs.items()}
            
            # Generate with streaming
            from transformers import TextStreamer
            streamer = TextStreamer(self.tokenizer, skip_prompt=True)
            
            generation_kwargs = dict(
                inputs,
                streamer=streamer,
                max_new_tokens=512,
                temperature=0.7,
                top_p=0.95,
                do_sample=True,
            )
            
            # This runs in a thread pool to not block
            import threading
            import queue
            
            q = queue.Queue()
            
            def generate():
                with torch.no_grad():
                    output = self.model.generate(**generation_kwargs)
                    text = self.tokenizer.decode(output[0], skip_special_tokens=True)
                    # Extract only the new part
                    new_text = text[len(prompt):]
                    q.put(new_text)
                    q.put(None)  # Signal done
            
            thread = threading.Thread(target=generate)
            thread.start()
            
            while True:
                try:
                    chunk = q.get(timeout=0.1)
                    if chunk is None:
                        break
                    yield chunk
                    await asyncio.sleep(0)
                except queue.Empty:
                    await asyncio.sleep(0.01)
        
        else:
            # Mock mode for testing without model
            words = prompt.split()
            response = f"This is a simulated response. You said: '{prompt[:50]}...' "
            for word in response.split():
                yield word + " "
                await asyncio.sleep(0.05)  # Simulate thinking