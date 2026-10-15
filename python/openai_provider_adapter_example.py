"""Official OpenAI Python SDK adapter CONTRACT demonstration.

No network requests when imported. Live tool loop and function schemas must be
implemented and verified in the app; arbitrary model arguments are untrusted.
"""
from dataclasses import dataclass
from typing import Literal

@dataclass(frozen=True)
class ProviderProfile:
    name: str
    model_id: str
    api_mode: Literal['responses','chat_completions']
    base_url: str | None
    vision: bool
    tools: bool
    image_edit: bool


def build_client(api_key: str, profile: ProviderProfile):
    from openai import OpenAI
    kwargs={'api_key':api_key,'timeout':30,'max_retries':2}
    if profile.base_url:
        kwargs['base_url']=profile.base_url
    return OpenAI(**kwargs)


def plain_text(client, profile: ProviderProfile, prompt: str) -> str:
    if profile.api_mode=='responses':
        response=client.responses.create(model=profile.model_id,input=prompt,store=False)
        return response.output_text
    response=client.chat.completions.create(
        model=profile.model_id, messages=[{'role':'user','content':prompt}]
    )
    return response.choices[0].message.content or ''

# Full tool calls: Responses uses response.output[].function_call and
# function_call_output with matching call_id; Chat Completions uses
# assistant.tool_calls + role=tool/tool_call_id. Dispatch only app-owned tools,
# with JSON Schema validation, user approval and finite max rounds.
