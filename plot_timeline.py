import matplotlib.pyplot as plt
import json

import numpy as np

def read_events_from_file(file_path):
    """
    Read events from a file and extract server_side_delay values.

    Args:
        file_path (str): Path to the JSON file containing events.

    Returns:
        list of float: List of server_side_delay values.
    """
    delays = []

    with open(file_path, 'r') as file:
        for line in file:
            try:
                json_data = json.loads(line)
                server_side_delay = json_data.get("server_side_delay")
                if server_side_delay is not None:
                    delays.append(server_side_delay)
            except json.JSONDecodeError:
                # Handle invalid JSON lines if necessary
                pass

    return delays


def plot_timeline(delays):
    """
    Plot a timeline of server_side_delays.

    Args:
        delays (list of float): List of server_side_delay values.
    """
    # Create a sequence of numbers to represent the requests
    request_numbers = list(range(1, len(delays) + 1))

    # Create a figure and axis
    fig, ax = plt.subplots(figsize=(10, 5))

    # Plot the delays on the timeline
    ax.plot(request_numbers, delays, marker='o', linestyle='-', markersize=1)

    # Calculate the mean of delays
    mean_delay = np.mean(delays)
    
    # Add a horizontal mean line
    ax.axhline(y=mean_delay, color='r', linestyle='--', label=f'Mean Delay: {mean_delay:.2f}')


    # Set labels for the x-axis (request sequence numbers)
    ax.set_xlabel('Request Sequence Number')
    ax.set_ylabel('API Delay [ms]')
    ax.set_title('Delays over time')

    # Display the plot
    plt.tight_layout()
    plt.savefig('testloop.png')


# Example usage:
if __name__ == "__main__":
    file_path = "testloop.out.json"  # Replace with the path to your JSON file
    delays = read_events_from_file(file_path)
    plot_timeline(delays)
