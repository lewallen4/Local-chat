import asyncio
from typing import AsyncGenerator, List, Dict, Any
from pathlib import Path

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


# ── Stop sequences ──────────────────────────────────────────────────
# These are every realistic way a model might try to start a new fake
# "user" turn. The more variants we cover, the less it can hallucinate.
STOP_SEQUENCES = [
    # Exact role prefixes the prompt uses
    "\nUSER:",
    "\nUser:",
    "\nuser:",
    # Common alternatives models learn from training data
    "\nHuman:",
    "\nHUMAN:",
    "\nhuman:",
    # Sometimes models write the full word
    "\n### Human",
    "\n### User",
    "\n[INST]",       # Mistral / Llama instruct format
    "\n<|user|>",     # Some chat templates
    "\n<human>",
    # Without leading newline as a safety net
    "User:",
    "Human:",
]


class ModelLoader:
    def __init__(self, model_path: str):
        self.model_path = Path(model_path)
        self.model      = None
        self.tokenizer  = None
        self.backend    = None
        self.load_model()

    def load_model(self):
        if not self.model_path.exists():
            raise FileNotFoundError(f"Model not found at {self.model_path}")

        if HAS_LLAMA_CPP:
            print(f"Loading model with llama.cpp: {self.model_path}")
            try:
                self.model = llama_cpp.Llama(
                    model_path=str(self.model_path),
                    n_ctx=2048,
                    n_threads=4,
                    n_gpu_layers=0,
                    verbose=False,
                    logits_all=False,
                    embedding=False,
                )
                self.backend = "llama.cpp"
                print("✅ Model loaded with llama.cpp")
                return
            except Exception as e:
                print(f"❌ llama.cpp failed: {e}")

        if HAS_TRANSFORMERS:
            print(f"Loading model with transformers: {self.model_path}")
            try:
                self.tokenizer = AutoTokenizer.from_pretrained(self.model_path.parent)
                self.model = AutoModelForCausalLM.from_pretrained(
                    self.model_path.parent,
                    torch_dtype=torch.float32,
                    low_cpu_mem_usage=True,
                )
                self.backend = "transformers"
                print("✅ Model loaded with transformers")
                return
            except Exception as e:
                print(f"❌ transformers failed: {e}")

        raise RuntimeError("No suitable backend found to load the model")

    async def generate_stream(self, context: Dict[str, Any]) -> AsyncGenerator[str, None]:
        prompt = context.get("prompt", "")

        if self.backend == "llama.cpp":
            try:
                stream = self.model(
                    prompt,
                    max_tokens=512,        # was 256 — gives the model room to finish a thought
                    temperature=0.7,
                    top_p=0.95,
                    repeat_penalty=1.1,    # discourages looping/repeating patterns
                    stop=STOP_SEQUENCES,
                    echo=False,
                    stream=True,
                )
                for chunk in stream:
                    text = chunk["choices"][0]["text"]
                    # Hard client-side guard: if a stop token somehow leaked
                    # through, strip it and end generation cleanly.
                    for stop in STOP_SEQUENCES:
                        if stop.strip() in text:
                            # Yield whatever came before the stop token
                            before = text[:text.find(stop.strip())]
                            if before:
                                yield before
                            return
                    yield text
                    await asyncio.sleep(0)
            except Exception as e:
                yield f"[Error during generation: {e}]"

        elif self.backend == "transformers":
            yield "This is a simulated response from the transformers backend."
            await asyncio.sleep(0.5)

        else:
            yield f"Mock response (no model loaded). Prompt preview: '{prompt[:50]}...'"
            await asyncio.sleep(0.1)
