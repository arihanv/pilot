import logging

from dotenv import load_dotenv
from livekit.agents import (
    Agent,
    AgentServer,
    AgentSession,
    JobContext,
    JobProcess,
    cli,
    room_io,
)
from livekit.plugins import google, silero

logger = logging.getLogger("agent")

load_dotenv(".env.local")


class VideoAssistant(Agent):
    def __init__(self) -> None:
        super().__init__(
            instructions="You are a helpful voice assistant with live video input from your user.",
            llm=google.realtime.RealtimeModel(
                voice="Puck",
                temperature=0.8,
            ),
        )


server = AgentServer()


def prewarm(proc: JobProcess):
    proc.userdata["vad"] = silero.VAD.load()


server.setup_fnc = prewarm


@server.rtc_session()
async def my_agent(ctx: JobContext):
    await ctx.connect()

    session = AgentSession()

    await session.start(
        agent=VideoAssistant(),
        room=ctx.room,
        room_options=room_io.RoomOptions(
            video_input=True,
            # ... noise_cancellation, etc.
        ),
    )


if __name__ == "__main__":
    cli.run_app(server)
