curl https://raw.githubusercontent.com/vectorch-ai/ScaleLLM/main/scalellm.yml -sSf > scalellm_compose.yml
HF_MODEL_ID=01-ai/Yi-34B-Chat-4bits DEVICE=cuda docker  max_tokens=8192 compose -f ./scalellm_compose.yml up
