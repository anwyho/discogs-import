# Discogs Import

This script (`ruby main.rb`) will:
1. Take a list of artist-albums (from say an organized note)
1. Look them up on the [Discogs API](https://www.discogs.com/developers/)
1. Ask you if it found the right album
1. Add the album to your Discogs Wantlist.

In order to get this to work, you'll have to:
- Create a Discogs API Personal Access Token
- Create a few environment variables in `.env ` 
- Tweak how the artist-album array is generated
- Answer a few questions in the command line
- Approve of adding these to Discogs.

My goal was to add all my wanted albums to Discogs so that I can check on [Zion's Gate Records' Discogs merchant page](https://www.discogs.com/seller/zionsgate/profile) to see if I can pick up some records while I'm in Seattle for a few days. 
They only have three on my wantlist (so was it worth three hours of my time 🥲) but one of them is [Men I Trust ‎– Forever Live Sessions](https://www.discogs.com/sell/item/3190905913) so.......

(Also here's [everything I asked ChatGPT](https://chatgpt.com/share/66e53115-c104-800c-a8dd-fcc772245324))

### Screenshot of the script in action

<img width="731" alt="Screenshot of running the Discogs script" src="https://github.com/user-attachments/assets/0d7881eb-9678-429b-93f4-29e2081cc281"> <img width="213" alt="Screenshot 2024-09-12 at 23 01 50" src="https://github.com/user-attachments/assets/6239355e-e8ee-4a03-baff-0891ab6e4f1c">


