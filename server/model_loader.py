import asyncio
from typing import AsyncGenerator, List, Dict, Any
import logging
import sys
from pathlib import Path

# Try importing different backends
try:
    import llama_cpp
    HAS_LLAMA_CPP = True
    print("✅ llama-cpp-python found")
except ImportError as e:
    HAS_LLAMA_CPP = False
    print(f"❌ llama-cpp-python not found: {e}")

try:
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    HAS_TRANSFORMERS = True
    print("✅ transformers found")
except ImportError as e:
    HAS_TRANSFORMERS = False
    print(f"❌ transformers not found: {e}")

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
        if HAS_LLAMA_CPP:
            print(f"Loading model with llama.cpp: {self.model_path}")
            try:
                self.model = llama_cpp.Llama(
                    model_path=str(self.model_path),
                    n_ctx=2048,  # Context window
                    n_threads=4,  # CPU threads
                    n_gpu_layers=0,  # Don't use GPU in GitHub Actions
                    verbose=False,
                    logits_all=False,
                    embedding=False
                )
                self.backend = "llama.cpp"
                print("✅ Model loaded successfully with llama.cpp")
                return
            except Exception as e:
                print(f"❌ llama.cpp loading failed: {e}")
        
        # Fall back to transformers
        if HAS_TRANSFORMERS:
            print(f"Loading model with transformers: {self.model_path}")
            try:
                # For GGUF files, transformers can't load them directly
                # This will only work if it's a proper transformers model
                self.tokenizer = AutoTokenizer.from_pretrained(self.model_path.parent)
                self.model = AutoModelForCausalLM.from_pretrained(
                    self.model_path.parent,
                    torch_dtype=torch.float32,
                    low_cpu_mem_usage=True
                )
                self.backend = "transformers"
                print("✅ Model loaded successfully with transformers")
                return
            except Exception as e:
                print(f"❌ Transformers loading failed: {e}")
        
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
            try:
                stream = self.model(
                    prompt,
                    max_tokens=256,
                    temperature=0.7,
                    top_p=0.95,
                    stop=["User:", "\nUser ", "Human:", "\nHuman "],
                    echo=False,
                    stream=True
                )
                
                for chunk in stream:
                    yield chunk["choices"][0]["text"]
                    await asyncio.sleep(0)
            except Exception as e:
                yield f"[Error during generation: {e}]"
        
        elif self.backend == "transformers":
            # Simplified transformers response for testing
            yield f"This is a simulated response from the transformers backend. Your prompt was: {prompt[:50]}..."
            await asyncio.sleep(0.5)
            yield " The model would generate more text here."
        
        else:
            # Mock mode for testing without model
            yield f"This is a mock response (no model loaded). Your message: '{prompt[:50]}...'"
            await asyncio.sleep(0.1)